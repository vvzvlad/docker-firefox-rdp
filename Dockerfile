FROM public.ecr.aws/lts/ubuntu:20.04_stable

ENV VNC_PASSWORD=""
ENV DEBIAN_FRONTEND="noninteractive"
ENV LC_ALL="C.UTF-8"
ENV LANG="en_US.UTF-8"
ENV LANGUAGE="en_US.UTF-8"
ENV RESOLUTION="1366x768x24"
ENV SCALE="1"

RUN	apt-get update
RUN	apt-get install -y fonts-takao pulseaudio supervisor x11vnc fluxbox mc xfce4 xrdp xvfb wget nano grep sudo
RUN	apt-get install awesome awesome-extra -y
RUN	apt install software-properties-common -y
RUN add-apt-repository ppa:mozillateam/ppa -y
RUN echo "Package: * Pin: release o=LP-PPA-mozillateam Pin-Priority: 1001" > /etc/apt/preferences.d/mozilla-firefox
RUN apt update -y
RUN apt install firefox -y
RUN	apt-get clean -y
RUN	apt-get autoremove -y
RUN	rm -rf /var/cache/* /var/log/apt/* /var/lib/apt/lists/* /tmp/*
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/root/.bash_history" && echo "$SNIPPET" >> "/root/.bashrc"

RUN	useradd -m -G pulse-access -p user user
RUN	{ echo "user"; echo "user"; } | passwd user
RUN	mkdir -p /home/user/.config/awesome/
RUN	cp /etc/xdg/awesome/rc.lua /home/user/.config/awesome/rc.lua

RUN	echo '\n\
pcall(require, "luarocks.loader")\n\
local gears = require("gears")\n\
local awful = require("awful")\n\
require("awful.autofocus")\n\
local wibox = require("wibox")\n\
local beautiful = require("beautiful")\n\
local naughty = require("naughty")\n\
local menubar = require("menubar")\n\
local hotkeys_popup = require("awful.hotkeys_popup")\n\
awful.util.spawn("/home/user/firefox_startup")\n\
client.connect_signal("property::minimized", function(c) c.maximized = true end)\n\
client.connect_signal("property::maximized", function(c) c.maximized = true end)\n\
\n\
		' > /home/user/.config/awesome/rc.lua

RUN	echo '#!/bin/bash \n\
DISPLAY=":1" firefox --kiosk $URL &\n\
\n\
		' > /home/user/firefox_startup
RUN	chmod +x /home/user/firefox_startup

RUN	echo "user_pref(\"layout.css.devPixelsPerPx\", "$SCALE");" > /home/user/firefox_userjs



RUN	chown -R user:user /home/user/
ADD conf/ /
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]


