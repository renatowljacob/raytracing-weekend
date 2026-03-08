#!/bin/sh

level=""

case $1 in
debug) level="-debug -o:none" ;;
release) level="-o:speed" ;;
esac

odin build . -keep-executable ${level}
