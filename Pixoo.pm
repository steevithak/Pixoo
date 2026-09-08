#!/usr/bin/env perl
use v5.42;
use feature 'class';
use feature 'try';
no warnings 'experimental::class', 'experimental::try';

use Socket qw(pack_sockaddr_un);
use Net::DBus;
use Imager;

class Pixoo {
    use JSON::MaybeXS;

    # RFCOMM Constants for sockets
    field $AF_BLUETOOTH   :param :reader = 31;
    field $BTPROTO_RFCOMM :param :reader = 3;

    # Protocol Commands
    field $CMD_SET_SYSTEM_BRIGHTNESS = 0x74;
    field $CMD_SET_BOX_MODE          = 0x45;
    field $CMD_SET_COLOR             = 0x6F;
    field $CMD_DRAW_PIC              = 0x44;
    field $CMD_DRAW_ANIM             = 0x49;

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

    # Set brightness
    # brightness is the percentage of full brightness: 0 - 100 %
    method set_brightness($brightness) {
        $self->_send($CMD_SET_SYSTEM_BRIGHTNESS, [$brightness & 0xFF]);
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
