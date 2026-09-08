## Perl Module for Controlling a Bluetooth Divoom Pixoo 16x16 Display

I found one of the old bluetooth-only Divoom Pixoo 16x16 LED displays in my
parts box and wanted to use it as a status display on a headless Fedora
GNU/Linux server I've been working on for LLM experiments. But when I looked
around for some open source software for the display, I couldn't find
anything that actually worked. I found several incomplete libraries that
could only send static images or animated GIFs and nothing else. But I
wanted to do a little more, like display colors, scrolling text and emojis.
So I decided to try reverse engineering the protocol on my own.

I used Google's Bluetooth HCI snoop log to capture the data stream going to
the display from an Android phone app as a starting point. Combined with
the still image code in some of those older open source libraries, I was
able to get protocol mostly sorted out and created a simple Perl module.

I've also included a sample Perl script called `demo.pl` that tests each
of the libraries functions, which include:

 - Displaying a static image in PNG, JPEG, or GIF format
 - Displaying an animated image in GIF format, with adjustable frame rate
 - Displaying a series of static images as an animation, with adjustable frame rate
 - Setting the full display to any RGB color
 - Setting the brightness of the display from 1-100%
 - Displaying any Unicode v16 Emoji by name or hex code-point
 - Displaying horizontally scrolling text, with adjustable scroll speed

Note that this code is for the old Bluetooth-only Pixoo, not the modern WiFi
version. I don't have access to a modern WiFi Pixoo so I don't know if it
could be easily adapted or not.

# Instructions to get things going

1. Connect to the Divoom Pixoo device from the command line. You'll probably
need to do these steps as root:

  - `# bluetoothctl`
  - `[]> power on`
  - `[]> agent on`
  - `[]> scan on`
  - Look for scan result with Pixoo or Divoom in the name note the MAC address.
    Also save the MAC for later, you'll need to add it to the demo.pl code too.
  - `[]> pair xx:xx:xx:xx:xx:xx`
  - `[]> trust xx:xx:xx:xx:xx:xx`
  - `[]> connect xx:xx:xx:xx:xx:xx`
  - `[]> exit`
  - At this point your Pixoo should be connect and will reconnect automatically
    each time you boot up.

2. Clone the Pixoo repo to your machine

3. Add the Pixoo's MAC address to the demo.pl script.

4. Run `./demo.pl` from repo directory and it should run through the demo of
   each Pixoo feature supported by the library.

# Copyright and License

This program is free software available under the same terms as Perl itself.
You may use it under the terms of the GPL V1 or any later version or
the terms of the Perl Artistic License.

## Credits for demo assets

# 16x16 Emoji library
From iamcal's emoji-data
https://github.com/iamcal/emoji-data
JSON database copyright (c) 2013 by Cal Henderson, MIT license
Images on sprite sheet are based on Google/Android images, Creative Commons Attribution 4.0 license

# Text font
Terminus-TTF
https://files.ax86.net/terminus-ttf/
Copyright (C) 2012 Dimitar Toshkov Zhekov
Licensed under the SIL Open Font License, version 1.1

# Animated GIF sample image
Sample Mario_Step.gif animation obtained from Wikimedia Commons
by Wikipedia user: New_editing_editor
License: Create Commons CC0 1.0 Universal Public Domain Dedication
https://commons.wikimedia.org/wiki/File:Mario_Step.gif

# 16x16 Skull image
Origin unknown, believed to be public domain

