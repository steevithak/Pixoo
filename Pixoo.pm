#!/usr/bin/env perl
use v5.42;
use feature 'class';
use feature 'try';
no warnings 'experimental::class', 'experimental::try';
use utf8;

use Socket qw(pack_sockaddr_un);
use Net::DBus;
use Imager;

class Pixoo {
    use JSON::MaybeXS;

    # RFCOMM Constants for sockets
    field $AF_BLUETOOTH   :param :reader = 31;
    field $BTPROTO_RFCOMM :param :reader = 3;

    # General Commands
    field $CMD_SET_BRIGHTNESS = 0x74;
    field $CMD_SET_DATETIME   = 0x18;
    field $CMD_SET_COLOR      = 0x6F;
    field $CMD_DRAW_ANIM      = 0x49;
    field $CMD_DRAW_PIC       = 0x44;
    field $CMD_SET_HOT        = 0x26;
    field $CMD_SET_WEATHER    = 0x5F;
    field $CMD_SET_TEMP_UNIT  = 0x2B;

    # View Commands
    field $CMD_SET_VIEW       = 0x45;
    field $VIEW_CLOCK         = 0x00;
    field $VIEW_COLOR_CYCLE   = 0x01;
    field $VIEW_DEMO_LOOP     = 0x02;
    field $VIEW_AUDIO         = 0x04;

    # Instance Fields
    field $mac_address :param :reader;
    field $btsock      :reader = undef;
    field $debug       :param :reader :writer = 0;
    field $emoji_data;
    field $emoji_sheet;

    # Debug logging to stderr
    method _log($msg) {
        return unless $debug;

        # Extract caller method name (e.g. "Pixoo::_encode_raw_image")
        my $caller_sub = (caller(1))[3] // 'Pixoo';
        # Strip class package prefix for cleaner logs ("_encode_raw_image")
        $caller_sub =~ s/.*:://;

        warn "[$caller_sub] $msg\n";
    }

    # Open a socket to the Pixoo using Bluetooth
    method connect() {
        return if $btsock;

        try {
            # Create RFCOMM Bluetooth Socket
            socket($btsock, $AF_BLUETOOTH, Socket::SOCK_STREAM(), $BTPROTO_RFCOMM)
                or die "Failed to create Bluetooth socket: $!";

            # Structure: bdaddr (6 bytes LE), channel (uint8_t)
            my @mac_bytes = map { hex($_) } reverse split(/:/, $mac_address);
            my $sockaddr  = pack('S C6 C x', $AF_BLUETOOTH, @mac_bytes, 1);

            CORE::connect($btsock, $sockaddr)
                or die "Failed to connect to $mac_address over RFCOMM: $!";
        }
        catch ($e) {
            $btsock = undef;
            die "Pixoo connection error: $e";
        }
    }

    # Close the Pixoo Bluetooth socket
    method disconnect() {
        if (defined $btsock) {
            close($btsock);
            $btsock = undef;
        }
    }

    ### Bluetooth protocol methods

    # Return a payload checksum
    method _checksum($payload_bytes) {
        # Sum all bytes excluding the start byte (byte 0)
        my $cs = 0;
        for (my $i = 1; $i < @$payload_bytes; $i++) {
            $cs = ($cs + $payload_bytes->[$i]) & 0xFFFF;
        }
        return $cs;
    }

    # Create a Bluetooth Serial Port Profile (SPP) packet
    method _spp_encode($cmd, $args = []) {
        my $payload_size = scalar(@$args) + 3;

        # Header: Start byte (0x01), Size (16-bit LE), Command
        my @frame = (
            0x01,
            $payload_size & 0xFF,
            ($payload_size >> 8) & 0xFF,
            $cmd
        );

        push @frame, @$args;

        # Checksum (16-bit LE) + End byte (0x02)
        my $cs = $self->_checksum(\@frame);
        push @frame, ($cs & 0xFF), (($cs >> 8) & 0xFF), 0x02;

        return pack('C*', @frame);
    }

    # Send a Bluetooth SPP package to the Pixoo
    method _send($cmd, $args = []) {
        $self->connect() unless defined $btsock;
        my $encoded = $self->_spp_encode($cmd, $args);
        syswrite($btsock, $encoded);
    }

    ### Pixoo commands

    # Set the Pixoo Date and Time.
    # Pass specific date and time or leave args empty for current time
    method set_datetime(%args) {
        my ($year, $month, $day, $hour, $min, $sec);

        if ($args{date} && $args{time}) {
            # Parse provided strings ("YYYY-MM-DD" and "HH:MM:SS")
            if ($args{date} =~ /^(\d{4})-(\d{2})-(\d{2})$/ && $args{time} =~ /^(\d{2}):(\d{2}):(\d{2})$/) {
                ($year, $month, $day) = ($1, $2, $3);
                ($hour, $min, $sec)   = ($4, $5, $6);
            }
            else {
                die "Invalid date/time format. Expected 'YYYY-MM-DD' and 'HH:MM:SS'\n";
            }
        }
        else {
            # Default to current system date and time
            my @now = localtime();
            $sec   = $now[0];
            $min   = $now[1];
            $hour  = $now[2];
            $day   = $now[3];
            $month = $now[4] + 1;       # localtime months are 0-11
            $year  = $now[5] + 1900;    # localtime years are years since 1900
        }

        # Year split: Year % 100 (e.g. 26) followed by Year / 100 (e.g. 20)
        my $year_lo = $year % 100;
        my $year_hi = int($year / 100);

        # Build the payload
        my @payload = (
            $year_lo,
            $year_hi,
            $month,
            $day,
            $hour,
            $min,
            $sec
        );

        $self->_log(sprintf("Setting device datetime to %04d-%02d-%02d %02d:%02d:%02d",
            $year, $month, $day, $hour, $min, $sec)) if $debug;

        # [0x18, year_lo, year_hi, month, day, hour, min, sec]
        $self->_send($CMD_SET_DATETIME, \@payload);
    }

    # Display the Pixoo clock and optionally the weather image, temp, and date.
    # The timing on my Pixoo is not adjustable and seems to be 28 seconds per
    # loop with all screens turned on:
    #   Clock         : 10 seconds
    #   Weather image :  6 seconds
    #   Temperature   :  6 seconds
    #   Date          :  6 seconds
    #
    # Arguments:
    #
    # * color: RGB color to be used in the clock face, eg. ff43b7
    #
    # * clock:  Clock face, integer 0-5
    #  0 = Default face. Large HH digits on top. Large :MM digits below.
    #      Color used for digits
    #  1 = Small HH:MM digits in specified color with animated rainbow
    #      bars above and below
    #  2 = Small HH digits above, :MM digits below surrounded by a cyan
    #      colored box. Color used to digits.
    #  3 = Analog clock with red minute hand, blue hour hand. Color is
    #      used as an outline.
    #  4 = Inverted version of face 0 with black digits. Color is used
    #      for the background color.
    #  5 = Analog clock with gray outline, black hour markers, blue minute
    #      hand, red hour hand. Color is used for face background.
    #
    # NOTE: Most of the protocol examples I could find suggested 0-15
    # were allowed for a total of 16 faces. Maybe that's true on newer
    # Pixoos but mine only has 6. You can pass up to 15 just in case.
    #
    # * twentyfour: boolean, 0 = 12 hour format, 1 = 24 hour format
    #   This doesn't work on early Pixoo models, they are always 12h
    #
    # * weather: show the weather condition animation corresponding to
    #   the weather condition set in send_weather(). Boolean.
    #   0 = don't show, 1 = show image
    #
    # * temp: show the temperature image. Boolean, 0 = don't show, 1 = show
    #
    # * calendar: show the date image. Boolean, 0 = don't show, 1 = sho1
    #
    method show_clock(%args) {
        my $clock      = $args{clock}      // 0;      # Clock face style ID (0-6)
        my $twentyfour = $args{twentyfour} // 0;      # 24h format / 12h format (0/1)
        my $weather    = $args{weather}    // 0;      # Weather display toggle (0/1)
        my $temp       = $args{temp}       // 0;      # Temperature display toggle (0/1)
        my $calendar   = $args{calendar}   // 0;      # Calendar display toggle (0/1)

        # Base payload for CMD_SET_VIEW (0x45)
        my @payload = (
            $VIEW_CLOCK,                             # Clock View (0x00)
            $twentyfour ? 0x01 : 0x00,               # Set 24/12 format if available
        );

        # Validate clock style ID (0..15)
        if (defined $clock && $clock >= 0 && $clock <= 15) {
            push @payload, $clock, 0x01;      # [clock_style, clock_on]
        }
        else {
            push @payload, 0x00, 0x00;        # [clock_style=0, clock_off]
        }

        # Add feature toggles
        push @payload, (
            $weather  ? 0x01 : 0x00,
            $temp     ? 0x01 : 0x00,
            $calendar ? 0x01 : 0x00,
        );

        # Append RGB color if provided
        if (defined $args{color}) {
            my ($r, $g, $b) = $self->_parse_hex_color($args{color});
            push @payload, ($r, $g, $b);
        }

        $self->_log(sprintf("Setting clock view (face: %d, 24h: %d, weather: %d, temp: %d, calendar: $calendar)",
                    $clock, $twentyfour, $weather, $temp, $calendar)) if $debug;

        # Send clock view command and payload
        my $res = $self->_send($CMD_SET_VIEW, \@payload);

        # Not really sure what this is, doesn't appear to do anything on my
        # Pixoo but some protocol examples included it. I'm hardcoding it to
        # the off state for safety.
        my @hot_payload = (0x00);
        $self->_send($CMD_SET_HOT, \@hot_payload);
    }

    # Update the Pixoo weather data.
    #
    # Arguments:
    #
    # * temp: The current temperature in degrees Celsius.
    #   Postive temps should be specified as an integer (e.g. 24, 72)
    #   Negative temps should include a dash (e.g. -16, -2)
    # * unit: Temperature unit (C/F), applies to temp and display mode
    # * weather: Weather condition, Integer 0-9
    #
    #  #   Image show                       Weather Condition
    #  0 = No image, may freeze display     -
    #  1 = Trees with blue sky              Sunny (forest)
    #  2 = Unused, my pixoo dupes #1        -
    #  3 = Buildings blue sky heavy clouds  Cloudy (urban)
    #  4 = Unused, may show #3 w/winds      Clouds/wind (urban)
    #  5 = Clouds, rain, lightening         Thunderstorm
    #  6 = Clouds, light rain               Rain
    #  7 = Unused, my pixoo dupes #5        -
    #  8 = Snow                             Snow
    #  9 = Trees with dark clouds           Fog/Haze (forest)
    #
    # Your results may vary on the weather images. Different firmware
    # version had slight variations in the animations.
    #
    method send_weather(%args) {
        $args{temp} //= 0;
        $args{unit} //= 'C';
        my $weather  = $args{weather} // 1;

        # Set C/F unit : 0x00 = C, 0x01 = F
        my $unit_byte = ($args{unit} =~ /^f/i) ? 0x01 : 0x00;

        # Clean up temp input to ensure syntax is usable (e.g. 72, -23, etc)
        my $temp_raw = 0;
        $temp_raw = int($1) if ($args{temp} =~ /(-?\d+)/);

        # Always send temp as Celsius regardless of units
        # Pixoo will re-convert to F on display if needed
        my $temp_c = $temp_raw;
        if ($unit_byte == 0x01) {
            my $temp_float = ($temp_raw - 32) * 5 / 9;
            $temp_c = int($temp_float + ($temp_float >= 0 ? 0.5 : -0.5));
        }

        # Convert to signed 8-bit integer byte (supports negative temps down to -128)
        my $temp_byte = pack("c", $temp_c);

        # Build and send weather payload: [temperature_byte, weather_type]
        my @weather_payload = (
            unpack("C", $temp_byte),
            int($weather)
        );

        $self->_log(sprintf("Sending weather update: temp=%d, unit=%s, type=%d",
                    $temp_raw, $args{unit}, $weather)) if $debug;

        $self->_send($CMD_SET_WEATHER, \@weather_payload);
        $self->_send($CMD_SET_TEMP_UNIT, [$unit_byte]);
    }


    # Set color cycle view
    # Arguments:
    #  * color and RGB color (e.g. 00ff00)
    #  * mode - integer 0-2
    #    1 = solid display of color
    #    2 = spectrum cycle (ignores color setting)
    #    3 = vertical blue/red stripes (ignore color)
    method set_color_cycle_view(%args) {
        my ($r, $g, $b) = $self->_parse_hex_color($args{color1} // "FFFFFF");
        my $brightness  = $args{brightness} // 100;
        my $mode = $args{mode} // 0;
        my @payload = ($VIEW_COLOR_CYCLE, $r, $g, $b, $brightness, $mode, 0x01);
        $self->_log("Switching to color cycle view") if $debug;
        $self->_send($CMD_SET_VIEW, \@payload);
    }

    # Run the demo mode - the same sequence that runs when you power up
    method set_demo_loop_view() {
        my @payload = ($VIEW_DEMO_LOOP);
        $self->_log("Switching to demo animation loop view") if $debug;
        return $self->_send(0x45, \@payload);
    }

    # Show and audio visualizer display using the built-in microphone
    # Available Modes:
    #  0 = Histogram - equalizer style
    #  1 = moving mouth
    #  2 = Rainbow double-historgram - waveform style
    #  3 = muppet with moving mouth
    #  4 = Green falling dots, dots expand vertically with volume
    #  5 = Weird green cartoon face, moving eyes/mouth
    #  6 = vertical left/right rainbow bar historgrams
    #  7 = Purple talking face, moving eyes/mouth
    #  8 = Falling colored dots, dot size grows with volume
    #  9 = Dancing Bart Simpson, more movement with volume
    # 10 = Old style light organ simulator
    # 11 = Dancing girl in forest, more movement with volume
    method set_audio_view($mode = 0) {
        my @payload = ($VIEW_AUDIO, $mode);
        $self->_log("Switching to audio visualizer view") if $debug;
        return $self->_send(0x45, \@payload);
    }

    # Set brightness
    # brightness is the percentage of full brightness: 0 - 100 %
    method set_brightness($brightness) {
        $self->_send($CMD_SET_BRIGHTNESS, [$brightness & 0xFF]);
    }

    # Set all LEDs on display to a color
    # r, g, b are one byte 0-255 values
    method set_color($r, $g, $b) {
        $self->_send($CMD_SET_COLOR, [$r & 0xFF, $g & 0xFF, $b & 0xFF]);
    }

    # Display a static image file on the Pixoo (png, jpeg, gif)
    method draw_pic($filepath) {
        my $img = Imager->new(file => $filepath)
            or die "Failed to open image '$filepath': " . Imager->errstr;

        my $frame = $self->_encode_animation_frame($img, 0);
        my @prefix = (0x00, 0x0A, 0x0A, 0x04);

        $self->_send($CMD_DRAW_PIC, [@prefix, @$frame]);
    }

    # Display an animated GIF file. Speed = delay between frames in ms
    method draw_gif($filepath, $speed = 100) {
        my @images = Imager->read_multi(file => $filepath)
            or die "Failed to read GIF frames from '$filepath': " . Imager->errstr;

        my @frames;

        for my $img (@images) {
            my $encoded = $self->_encode_animation_frame($img, $speed);
            push @frames, @$encoded;
        }

        $self->_send_animation_chunks(\@frames);
    }

    # Display an animate from individual static files.
    # filepaths is an array of frame images
    # speed is delay between frames in ms
    method draw_anim($filepaths, $speed = 100) {
        my @frames;

        for my $path (@$filepaths) {
            my $img = Imager->new(file => $path)
                or die "Failed to read frame '$path': " . Imager->errstr;

            my $encoded = $self->_encode_animation_frame($img, $speed);
            push @frames, @$encoded;
        }

        $self->_send_animation_chunks(\@frames);
    }

    # Scroll text across Pixoo screen. The Pixoo seems to have very limited
    # frame buffer memory. If you exceed the memory it will truncate the
    # string before the end. I haven't found an easy way to determine in
    # advance if a string will be too long since it's affected by other
    # factors like the animation speed, the font size, etc.
    method scroll_text_anim(%args) {
        my $text      = $args{text}      // "Hello World!";
        my $speed_ms  = $args{speed_ms}  // 10;
        my $step_px   = $args{step_px}   // 2;
        my $font_path = $args{font}      // 'assets/terminus/TerminusTTF-4.49.3.ttf';
        my $font_size = $args{font_size} // 12;

        # Parse text color (Default: White #FFFFFF)
        my ($r, $g, $b) = $self->_parse_hex_color($args{color} // $args{fg_color}, 255, 255, 255);

        # Parse background color (Default: Black #000000)
        my ($bg_r, $bg_g, $bg_b) = $self->_parse_hex_color($args{bg_color}, 0, 0, 0);

        unless (-f $font_path) {
            die "Font file not found: $font_path\n";
        }

        my $font = Imager::Font->new(file => $font_path, size => $font_size)
            or die Imager->errstr;

        my $bbox        = $font->bounding_box(string => $text);
        my $text_width  = $bbox->display_width;
        my $total_width = $text_width + 24;

        $self->_log(sprintf("Generating scroll animation for '%s' (%dx16 canvas, step:%dpx, step time:%dms)", 
            $text, $total_width, $step_px, $speed_ms)) if $debug;

        # 1. Render wide canvas filled with background color
        my $wide_img = Imager->new(xsize => $total_width, ysize => 16, channels => 3);
        $wide_img->box(
            filled => 1, 
            color  => Imager::Color->new($bg_r, $bg_g, $bg_b)
        );

        # 2. Draw text string over background
        $wide_img->string(
            font  => $font,
            text  => $text,
            x     => 16,
            y     => 12,
            color => Imager::Color->new($r, $g, $b),
            aa    => 0
        );

        # 3. Slice canvas using $step_px stride
        my @animation_chunks;
        my $max_x    = $total_width - 16;
        my $frame_cnt = 0;

        for (my $x = 0; $x <= $max_x; $x += $step_px) {
            my $crop = $wide_img->crop(
                left   => $x,
                top    => 0,
                width  => 16,
                height => 16
            );

            my $encoded_frame = $self->_encode_animation_frame($crop, $speed_ms);
            push @animation_chunks, @$encoded_frame;

            $frame_cnt++;
        }

        $self->_log(sprintf("Encoded %d frames (%d total bytes). Transmitting...", 
            $frame_cnt, scalar(@animation_chunks))) if $debug;

        return $self->_send_animation_chunks(\@animation_chunks);
    }

    # Draw a Unicode v16 emoji. The emojis are based on the iamcal-data
    # sprite sheet and JSON database. https://github.com/iamcal/emoji-data
    # JSON database by Cal Henderson, licensed under MIT License
    # Images on spritesheet from Google Android, licensed under Apache 2.0.
    # The emoji key can be specified in two ways:
    #   short name:   smile ( or :smile: )
    #   code point:   1f603
    # Note that emojis with multiple code points are separated by a dash:
    #   :lime: = 1f34b-200d-1f7e9
    # args:
    #  key - emoji code point or name (see comment above)
    #  bg_color - background color in hex (e.g. red = FF0000), default to black
    method draw_emoji(%args) {
        # Lazy load if not already initialized
        $self->load_emoji_assets() unless $emoji_data && $emoji_sheet;

        my $key = lc($args{emoji});
        # Strip wrapping colons if passed like ":smile:"
        $key =~ s/^:|:$//g;

        my $meta = $emoji_data->{$key};
        unless ($meta) {
            die "Emoji $args{emoji} not found in emoji.json mapping\n";
        }

        my ($bg_r, $bg_g, $bg_b) = $self->_parse_hex_color($args{bg_color}, 0, 0, 0);

        # Calculate pixel offsets on sheet (16px per grid square)
        my $crop_x = ($meta->{sheet_x} * 18) + 1;
        my $crop_y = ($meta->{sheet_y} * 18) + 1;

        $self->_log(sprintf("Drawing emoji '%s' from sheet offset (%d, %d)", $key, $crop_x, $crop_y)) if $debug;

        # Extract 16x16 region from sprite sheet
        my $raw_crop = $emoji_sheet->crop(
            left   => $crop_x,
            top    => $crop_y,
            width  => 16,
            height => 16
        );

        # Flatten transparent PNG pixels onto a solid RGB background canvas
        my $canvas = Imager->new(xsize => 16, ysize => 16, channels => 3);
        $canvas->box(
            filled => 1,
            color => Imager::Color->new($bg_r, $bg_g, $bg_b)
        );
        $canvas->compose(src => $raw_crop, tx => 0, ty => 0);

        # Encode frame and send using same protocol as draw_pic()
        my $frame = $self->_encode_animation_frame($canvas, 0);
        my @prefix = (0x00, 0x0A, 0x0A, 0x04);
        return $self->_send($CMD_DRAW_PIC, [@prefix, @$frame]);
    }


    # Image and palette helpers

    # Ensure all images are 16x16 pixels and 8 bit color
    # Extract pallete and covert data to Pixoo format
    method _encode_raw_image($img) {
        my $orig_w = $img->getwidth();
        my $orig_h = $img->getheight();
        $self->_log("Source image dimensions: ${orig_w}x${orig_h}");

        # Convert image to 8-bit direct RGB
        my $work_img = $img->to_rgb8()
            or die "Failed to convert image to RGB: " . Imager->errstr;

        # Force 16x16 dimensions
        my $scaled = $work_img->scaleX(pixels => 16)->scaleY(pixels => 16)
            or die "Failed to scale image to 16x16: " . Imager->errstr;

        my $scaled_w = $scaled->getwidth();
        my $scaled_h = $scaled->getheight();
        $self->_log("Scaled image dimensions: ${scaled_w}x${scaled_h}");

        my @palette;
        my %palette_index;
        my @pixels;

        # Extract 16x16 pixels and generate palette
        for my $y (0 .. 15) {
            for my $x (0 .. 15) {
                my $color = $scaled->getpixel(x => $x, y => $y)
                            // Imager::Color->new(0, 0, 0);

                my ($r, $g, $b) = $color->rgba;
                my $key = "$r,$g,$b";

                unless (exists $palette_index{$key}) {
                    push @palette, [$r, $g, $b];
                    $palette_index{$key} = $#palette;
                }
                push @pixels, $palette_index{$key};
            }
        }

        my $nb_colors = scalar(@palette);
        $self->_log("Palette count: $nb_colors colors");

        # Calculate bit-width per index (e.g., 2 colors = 1 bit, 61 colors = 6 bits)
        my $bitwidth = 1;
        if ($nb_colors > 1) {
            $bitwidth = int(log($nb_colors) / log(2) + 0.999999);
        }
        $self->_log("Calculated bitwidth per pixel index: $bitwidth bits");

        # Bit-pack pixel palette indices into bytes
        my $bit_buffer = 0;
        my $bits_in_buffer = 0;
        my @encoded_data;

        for my $idx (@pixels) {
            $bit_buffer |= ($idx << $bits_in_buffer);
            $bits_in_buffer += $bitwidth;

            while ($bits_in_buffer >= 8) {
                push @encoded_data, ($bit_buffer & 0xFF);
                $bit_buffer >>= 8;
                $bits_in_buffer -= 8;
            }
        }

        if ($bits_in_buffer > 0) {
            push @encoded_data, ($bit_buffer & 0xFF);
        }

        $self->_log("Encoded pixel byte payload size: " . scalar(@encoded_data) . " bytes");

        # Flatten palette to byte list [R0, G0, B0, R1, G1, B1, ...]
        my @flat_palette;
        for my $rgb (@palette) {
            push @flat_palette, @$rgb;
        }

        return ($nb_colors, \@flat_palette, \@encoded_data);
    }

    # Encode image as an animation frame
    # speed is the delay time per frame in ms
    method _encode_animation_frame($img, $speed) {
        $self->_log("Encoding frame with speed ${speed}ms");

        my ($nb_colors, $palette, $pixel_data) = $self->_encode_raw_image($img);
        my $frame_size = 7 + scalar(@$pixel_data) + scalar(@$palette);

        my @header = (
            0xAA,
            $frame_size & 0xFF,
            ($frame_size >> 8) & 0xFF,
            $speed & 0xFF,
            ($speed >> 8) & 0xFF,
            0x00,
            $nb_colors
        );

        return [@header, @$palette, @$pixel_data];
    }

    # Chop of big animations in data packets small enough for the Pixoo
    method _send_animation_chunks($frames, $chunk_size = 200) {
        my $total_size = scalar(@$frames);
        my $nchunks    = int(($total_size + $chunk_size - 1) / $chunk_size);

        $self->_log("Sending $total_size total frame bytes across $nchunks chunks");

        for (my $i = 0; $i < $nchunks; $i++) {
            my $offset = $i * $chunk_size;
            my $length = ($offset + $chunk_size > $total_size) ? ($total_size - $offset) : $chunk_size;

            my @chunk_data = @$frames[$offset .. ($offset + $length - 1)];
            my @header     = ($total_size & 0xFF, ($total_size >> 8) & 0xFF, $i);

            $self->_send($CMD_DRAW_ANIM, [@header, @chunk_data]);
        }
    }

    # Parse CSS style color hex strings ("0000FF", "#060606", or "000") to ($r, $g, $b)
    method _parse_hex_color($hex_str, $default_r = 0, $default_g = 0, $default_b = 0) {
        return ($default_r, $default_g, $default_b) unless defined $hex_str;

        # Strip leading '#' if present
        $hex_str =~ s/^#//;

        # Handle 6-digit hex (#RRGGBB)
        if ($hex_str =~ /^([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$/) {
            return (hex($1), hex($2), hex($3));
        }
        # Handle 3-digit shorthand (#RGB)
        elsif ($hex_str =~ /^([0-9a-fA-F])([0-9a-fA-F])([0-9a-fA-F])$/) {
            return (hex($1 x 2), hex($2 x 2), hex($3 x 2));
        }

        # Return default if parsing failed
        return ($default_r, $default_g, $default_b);
    }

    # Load the Unicode emoji sprite sheet and JSON database
    method load_emoji_assets($json_path  = 'assets/emoji-data/emoji.json',
                             $sheet_path = 'assets/emoji-data/sheet_google_16.png') {
        # Load JSON mapping file
        open my $fh, '<:raw', $json_path or die "Could not open emoji JSON '$json_path': $!";
        my $json_text = do { local $/; <$fh> };
        close $fh;

        my $raw_data = decode_json($json_text);

        # Build hash map indexing short_names (e.g. 'smile', 'thumbsup') and hex code points
        $emoji_data = {};
        for my $item (@$raw_data) {
            # Map by unified hex code (e.g. "1F600")
            if ($item->{unified}) {
                $emoji_data->{lc $item->{unified}} = $item;
            }
            # Map by short_name (e.g. "smile")
            if ($item->{short_name}) {
                $emoji_data->{lc $item->{short_name}} = $item;
            }
            # Map by alternative short_names
            if ($item->{short_names} && ref $item->{short_names} eq 'ARRAY') {
                for my $sn (@{ $item->{short_names} }) {
                    $emoji_data->{lc $sn} = $item;
                }
            }
        }

        # Load sprite sheet PNG into buffer
        unless (-f $sheet_path) {
            die "Emoji sprite sheet not found at '$sheet_path'\n";
        }

        $emoji_sheet = Imager->new();
        $emoji_sheet->read(file => $sheet_path)
            or die "Failed to read emoji sheet '$sheet_path': " . $emoji_sheet->errstr;

        $self->_log("Loaded emoji database and sprite sheet successfully.") if $debug;
    }
}

1;
