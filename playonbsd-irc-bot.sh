#!/usr/bin/env ksh
########
# Copyright (c) 2019 Thomas Frohwein <11335318+rfht@users.noreply.github.com>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
########

# You need to set CLIENT_ID (for Twitch API) and NICK/PASS/CHAN
# (for freenode registration/login) and FOLLOWER_ID (for searching through
# streams of followed users which is necessary for speed reasons)
CLIENT_ID=
NICK=
PASS=
CHAN=
# the follower is the account whose followed channels will be searched for
# a matching, active stream
FOLLOWER_ID=

# TODO
# automatically recover from disconnect
# diagnose false positives from already terminated streams -> look for what is
#    displayed after 'TYPE:'
# add a way to add nicks to karma.txt when they JOIN (':<NICK>! [...] JOIN [...]')
# add cleanup of $ACTIVE_STREAMS
# fix TODOs and FIXMEs inline

SERVER=irc.freenode.net
PORT=6667
CURSOR=
ACTIVE_STREAM_IDS=
KARMA_FILE="$(dirname $0)/karma.txt"
CONFIG_FILE="$(dirname $0)/bot.config"
LAST_HR=
CURRENT_HR=

if [ -f "$CONFIG_FILE" ] ; then
	. "$CONFIG_FILE"
else
	echo "Error: couldn't find bot.config"
	exit 1
fi

# Check that essential variables are not empty
[ -z "$CLIENT_ID" ] && echo "Error: Missing required variable CLIENT_ID in bot.config" && exit 1
[ -z "$NICK" ] && echo "Error: Missing required variable NICK in bot.config" && exit 1
[ -z "$PASS" ] && echo "Error: Missing required variable PASS in bot.config" && exit 1
[ -z "$CHAN" ] && echo "Error: Missing required variable CHAN in bot.config" && exit 1
[ -z "$FOLLOWER_ID" ] && echo "Error: Missing required variable FOLLOWER_ID in bot.config" && exit 1

if [ !  -f "$KARMA_FILE" ] ; then
	touch "$KARMA_FILE"
fi

quit()
{
	pkill -P $$
	exit
}

ctrl_c()
{
	echo "** Trapped CTRL-C"
	quit
}

trap ctrl_c INT

gameid2name()
{
	echo "$(curl -sH "Client-ID: $CLIENT_ID" \
		-X GET "https://api.twitch.tv/helix/games?id=$1" \
		| grep -Eo "\"name\":\"[^\"]*\"" \
		| tr -d '\"' | cut -d : -f 2-)"
}

update_names()
{
	# get list of names from $ACTIVE_NAMES and add to $KARMA_FILE if not there yet
	for name in $ACTIVE_NAMES; do
		# sanitize name
		name="$(echo "$name" | tr -cd "[:alnum:]_-")"
		if [ -z "$(grep -E "^$name:" "$KARMA_FILE")" ] ; then
			echo "$name:0" >> "$KARMA_FILE"
		fi
	done
}

adjust_karma()
{
	# adjust if name is in the list of channel names
	old_karma=$(get_karma "$1")
	if [ -n "$old_karma" ] ; then
		set_karma "$1" $((old_karma $2))
	else
		return 1
	fi
}

get_followed_channels()
{
	# FIXME: limited to 100 channels for now because it doesn't
	# follow the pagination/cursor.
	TWITCH_FOLLOWS="$(curl -sH "Client-ID: $CLIENT_ID" \
		-X GET "https://api.twitch.tv/helix/users/follows?from_id=${FOLLOWER_ID}&first=100")"
	# preserve the newline \n to keep separate numeric entries
	FOLLOWED_CHANS="$(echo "$TWITCH_FOLLOWS" \
		| grep -Eo "\"to_id\":\"[0-9]+\"" \
		| tr -cd "[:digit:]\n")"
}

update_user_list()
{
	# add the follower channel itself to the watched channels
	USER_LIST="&user_id=$FOLLOWER_ID"
	for idnum in $FOLLOWED_CHANS; do
		USER_LIST="$USER_LIST&user_id=$idnum";
	done
}

get_karma()
{
	# read karma from $KARMA_FILE
	if [ -z "$(grep -E "^$1:" "$KARMA_FILE")" ] ; then
		# return silently
		return 1
	fi
	echo $(grep -E "^$1:" "$KARMA_FILE" \
		| sed -E 's/^.*:(\-?[0-9]+)/\1/')
}

set_karma()
{
	sed -E -i "s/^$1:.*$/$1:$2/" "$KARMA_FILE"
}

streaminfo()
{
	while :
	do
		# update USER_LIST from followed channels only once an hour
		CURRENT_HR=$(date -j +"%H")
		if [ -z "$LAST_HR" ] ; then
			get_followed_channels
			update_user_list
			echo "[INFO] USER_LIST updated: $USER_LIST"
		elif [ $CURRENT_HR -ne $LAST_HR ] ; then
			get_followed_channels
			update_user_list
			echo "[INFO] USER_LIST updated: $USER_LIST"
		fi
		LAST_HR=$CURRENT_HR
		PARAMS=
		if [ -n "$CURSOR" ] ; then
			PARAMS="?after=$CURSOR&"
		else
			PARAMS="?"
		fi
		PARAMS="${PARAMS}first=100${USER_LIST}"
		STREAMS="$(curl -sH "Client-ID: $CLIENT_ID" \
			-X GET "https://api.twitch.tv/helix/streams$PARAMS")"
		CURSOR="$(echo "$STREAMS" \
			| grep -Eo "pagination.*" | cut -c 24- | rev | cut -c 4- | rev)"
		STREAM_STRING=
		STREAM_STRING=$(echo "$STREAMS" | grep -Eoi "[^{]*playonbsd[^}]*")
		if [ -n "$STREAM_STRING" ] ; then
			STREAM_ID=
			STREAM_ID="$(echo "$STREAM_STRING" | grep -Eo "\"id\":[^,]*" \
				| tr -d '\"' | cut -d : -f 2-)"
			if [ -z "$(echo "$ACTIVE_STREAM_IDS" | grep "$STREAM_ID")" ] ; then
				USER_NAME=
				GAME_ID=
				GAME_NAME=
				TITLE=
				VIEWER_COUNT=
				TYPE=
				USER_NAME="$(echo "$STREAM_STRING" | grep -Eo "\"user_name\":\"[^\"]*\"" \
					| tr -d '\"' | cut -d : -f 2-)"
				GAME_ID="$(echo "$STREAM_STRING" | grep -Eo "\"game_id\":\"[^\"]*\"" \
					| tr -d '\"' | cut -d : -f 2-)"
				GAME_NAME="$(gameid2name $GAME_ID)"
				TITLE="$(echo "$STREAM_STRING" | grep -Eo "\"title\":\"[^\"]*\"" \
					| tr -d '\"' | cut -d : -f 2-)"
				VIEWER_COUNT="$(echo "$STREAM_STRING" | grep -Eo "\"viewer_count\":[^,]*" \
					| tr -d '\"' | cut -d : -f 2-)"
				TYPE="$(echo "$STREAM_STRING" | grep -Eo "\"type\":\"[^\"]*\"" \
					| tr -d '\"' | cut -d : -f 2-)"
				print -p "PRIVMSG #openbsd-gaming :Stream live at https://www.twitch.tv/$USER_NAME, game: $GAME_NAME, $TITLE, viewers: $VIEWER_COUNT, TYPE: $TYPE"
				ACTIVE_STREAM_IDS="${ACTIVE_STREAM_IDS}${STREAM_ID}:"
			fi
		fi
		sleep 2
	done
}

{
	# register
	cat << EOF
NICK $NICK
USER $NICK 0.0.0.0 playonbsd.com :PlayOnBSD
PRIVMSG NickServ :IDENTIFY $NICK $PASS
JOIN $CHAN
EOF

	while read line ; do
		echo "$line"
	done
	echo QUIT
} | nc $SERVER $PORT |&

{
	while read -p line; do
		case "$line" in
			PING\ *) print -p "$(echo "$line" | sed -E 's/PING/PONG/')" ;\
				echo "[PONG] $line";;
			*++*)
				NICK="$(echo "$line" \
					| grep -Eo "[a-zA-Z0-9_]*\+\+" | head -1 \
					| rev | cut -c 3- | rev)"
				if [ \( -n "$NICK" \) \
					-a \( -n "$(grep -E "^$NICK:" "$KARMA_FILE")" \) ]
				then
					if [ -n "$(echo "$line" | grep -Eo "^:$NICK!")" ] ; then
						adjust_karma "$NICK" -1
						print -p "PRIVMSG $CHAN :trying to increase your own karma is selfish. karma decreased for $NICK to $(get_karma "$NICK")"
					else
						adjust_karma "$NICK" +1
						print -p "PRIVMSG $CHAN :karma increased for $NICK to $(get_karma "$NICK")"
					fi
					echo "[KARMA] $line"
				else
					echo "[IGNORE] $line"
				fi;;
			*--*)
				NICK="$(echo "$line" \
					| grep -Eo "[a-zA-Z0-9_]*\-\-" | head -1 \
					| rev | cut -c 3- | rev)"
				if [ \( -n "$NICK" \) \
					-a \( -n "$(grep -E "^$NICK:" "$KARMA_FILE")" \) ]
				then
					if [ -n "$(echo "$line" | grep -Eo "^:$NICK!")" ] ; then
						print -p "PRIVMSG $CHAN :you can't decrease your own karma. leave that to others, silly."
					else
						adjust_karma "$NICK" -1
						print -p "PRIVMSG $CHAN :karma decreased for $NICK to $(get_karma "$NICK")"
					fi
					echo "[KARMA] $line"
				else
					echo "[IGNORE] $line"
				fi;;
			*\?\?*)
				NICK="$(echo "$line" \
					| grep -Eo "[a-zA-Z0-9_]*\?\?" | head -1 \
					| rev | cut -c 3- | rev)"
				if [ \( -n "$NICK" \) \
					-a \( -n "$(grep -E "^$NICK:" "$KARMA_FILE")" \) ]
				then
					print -p "PRIVMSG $CHAN :$NICK's karma: $(get_karma "$NICK")"
					echo "[KARMA] $line"
				else
					echo "[IGNORE] $line"
				fi;;
			*\ 353\ *$CHAN*)
				echo "[NAMES] $line\n$ACTIVE_NAMES"
				ACTIVE_NAMES=$(echo "$line" \
					| sed -E 's,^.* 353 [^:]*:(.*)$,\1,' | tr -d '@')
				update_names
				;;
			*\ JOIN\ $CHAN)
				echo "[NAMES] $line\n$ACTIVE_NAMES"
				ACTIVE_NAMES=$(echo "$line" \
					| sed -E 's,^.* 353 [^:]*:(.*)$,\1,' | tr -d '@')
				update_names
				;;
			*) echo "[IGNORE] $line";;
		esac
	done
} &

{
	sleep 15	# in order to not start before registered and able to post
	streaminfo
} &

while read line; do
	case "$line" in
		# SHOW <variable> -> shows the value of a variable of the script
		SHOW\ *) eval "echo \${$(echo "$line" \
			| sed -E 's/SHOW[[:blank:]]+//')}";;
		# CALL <function/command> -> call a command/function in the script
		CALL\ *) $(echo "$line" \
			| sed -E 's/CALL[[:blank:]]+//');;
		*) print -p "$line";;
	esac
done

quit
