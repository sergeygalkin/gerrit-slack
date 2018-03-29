#!/bin/bash -e
WDIR=$(cd `dirname "${BASH_SOURCE[0]}"` && pwd)
cd ${WDIR}
cd ..
tmux new-session -s gerrit-slack-bot -d "./bin/gerrit-slack"
