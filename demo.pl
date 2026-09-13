#!/usr/bin/env perl
use v5.42;
use feature 'try';
use feature 'class';
no warnings 'experimental::class', 'experimental::try';
use utf8;

use FindBin;
use lib $FindBin::Bin; # Loads Pixoo.pm from the script's directory
use Pixoo;

# Set this to actual MAC address of your PIXOO
my $mac = '11:75:58:7C:23:A5';

my $img1 = 'assets/skull.png';
my $img2 = 'assets/Mario_Step.gif';

die "Error: File '$img1' does not exist.\n" unless -f $img1;
die "Error: File '$img2' does not exist.\n" unless -f $img2;

say "Connecting to Pixoo device at $mac...";

# Initialize and connect
my $pixoo = Pixoo->new(
    mac_address => $mac,
    debug       => 1
);

try {
    $pixoo->connect();
    say "Connected successfully!";

    # clear screen to black
    $pixoo->set_color(0,0,0);
    sleep(1);

    # Set date and time to system time
    $pixoo->set_datetime();
    sleep(1);

    # Send weather data (68F + Rain)
    $pixoo->send_weather(
        temp    => 68,
        unit    => 'f',
        weather => 6
    );
    sleep(1);

    # Show clock face 0 with weather, temp, and date
    $pixoo->show_clock(
        clock      => 0,        # style
        twentyfour => 1,        # 1 = 24h / 0 = 12h
        color      => "ff43b7", # RGB background color
        weather    => 1,        # 0 no weather image / show weather image
        temp       => 1,        # 0 no temp / 1 show temp
        calendar   => 1,        # 0 no date / show date on
    );
    sleep(28);

    # Show the clock face 1
    $pixoo->show_clock(
        clock      => 1,        # style
        twentyfour => 0,        # 1 = 24h / 0 = 12h
        color      => "00FF00", # RGB background color
        weather    => 0,        # 0 weather off / weather on (not sure if pixoo supports this)
        temp       => 0,        # 0 no temp / 1 show temp
        calendar   => 0,        # 0 date off / date on
    );
    sleep(2);

    # Show the clock face 2
    $pixoo->show_clock(
        clock      => 2,        # style
        twentyfour => 0,        # 1 = 24h / 0 = 12h
        color      => "0000ff", # RGB background color
        weather    => 0,        # 0 weather off / wether on (not sure if pixoo supports this)
        temp       => 0         # 0 no temp / 1 show temp
    );
    sleep(2);

    # Show the clock face 3
    $pixoo->show_clock(
        clock      => 3,        # style
        twentyfour => 0,        # 1 = 24h / 0 = 12h
        color      => "00ff00", # RGB background color
        weather    => 0,        # 0 weather off / wether on (not sure if pixoo supports this)
        temp       => 0         # 0 no temp / 1 show temp
    );
    sleep(2);

    # Show the clock face 4
    $pixoo->show_clock(
        clock      => 4,        # style
        twentyfour => 0,        # 1 = 24h / 0 = 12h
        color      => "FF0000", # RGB background color
        weather    => 0,        # 0 weather off / wether on (not sure if pixoo supports this)
        temp       => 0         # 0 no temp / 1 show temp
    );
    sleep(2);

    # Show the clock face 5
    $pixoo->show_clock(
        clock      => 5,        # style
        twentyfour => 0,        # 1 = 24h / 0 = 12h
        color      => "0000ff", # RGB background color
        weather    => 0,        # 0 weather off / wether on (not sure if pixoo supports this)
        temp       => 0         # 0 no temp / 1 show temp
    );
    sleep(2);

    # 0 solid color
    # 1 cycle through spectrum (ignores color)
    # 2 stationary red/blue vert stripes?
    $pixoo->set_color_cycle_view(
        color      => "0000ff",
        brightness => 100,
        mode       => 1,
    );
    sleep(10);

    # Set brightness
    say "Setting brightness to 100%...";
    $pixoo->set_brightness(100);
    sleep(1);

    # display an RGB color
    say "Setting color to 255, 0, 128";
    $pixoo->set_color(255,0,128);
    sleep(1);

    # display static image file
    say "Drawing image: $img1";
    $pixoo->draw_pic($img1);
    say "Waiting 2 seconds";
    sleep(2);

    # display an RGB color
    say "Setting color to 128, 0, 255";
    $pixoo->set_color(128,0,255);
    sleep(1);

    # display an animated GIF file
    say "Drawing image: $img2";
    $pixoo->draw_gif($img2, 100);
    sleep(4);

    # display an RGB color
    say "Setting color to 20, 160, 255";
    $pixoo->set_color(225,225,10);
    sleep(1);

    # display an emoji
    say "Drawing an emoji";
    $pixoo->draw_emoji(emoji => ':thumbsup:');     # thumbsup
    sleep(2);
    $pixoo->draw_emoji(emoji => '1F389');          # party popper
    sleep(2);
    $pixoo->draw_emoji(emoji => 'smile');          # smiley
    sleep(2);
    $pixoo->draw_emoji(emoji => 'smile', bg_color => '0000ff'); # smiley on blue
    sleep(2);

    # Emoji by simple name
    $pixoo->draw_emoji(emoji => 'lime', bg_color => 'ff0000' );
    sleep(2);
    # Emoji by simple :name:
    $pixoo->draw_emoji(emoji => ':lime:', bg_color => '00ff00' );
    sleep(2);
    # Emoji by code point
    $pixoo->draw_emoji(emoji => '1f34b-200d-1f7e9', bg_color => '0000ff' );
    sleep(2);

    # Set brightness 
    say "Setting brightness to 100%...";
    $pixoo->set_brightness(75);
    sleep(1);
    $pixoo->set_brightness(50);
    sleep(1);
    $pixoo->set_brightness(25);
    sleep(1);
    $pixoo->set_brightness(0);
    sleep(1);
    $pixoo->set_brightness(25);
    sleep(1);
    $pixoo->set_brightness(50);
    sleep(1);
    $pixoo->set_brightness(75);
    sleep(1);
    $pixoo->set_brightness(100);

    # Send scrolling text (good for about 30 chars +- depending on size and step)
    $pixoo->scroll_text_anim(
        text      => "ABCDEFGHIJKLMNOPQRSTUVWXYZ 1234567890 <<<<<<* ",
        speed_ms  => 100,
        step_px   => 2,
        color     => '0000ff',
        bg_color  => '101010',
    );
    sleep(20);

    # Turn on audio visualizer
    $pixoo->set_audio_view(2);
    sleep(60);

    # Run the demo
    $pixoo->set_demo_loop_view();
    sleep(1);
}
catch ($e) {
    warn "Failed to communicate with Pixoo: $e\n";
}
finally {
    $pixoo->disconnect();
    say "Disconnected.";
}

