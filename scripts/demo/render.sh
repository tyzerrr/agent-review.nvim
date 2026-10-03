#!/usr/bin/env bash
# README用のデモ動画を作る。引数を省くと scripts/demo/demo.tape から assets/demo.mp4 を作る。
#   scripts/demo/render.sh [tape] [out.mp4]
#   例) scripts/demo/render.sh scripts/demo/demo-pr.tape assets/demo-pr.mp4（PRレビューのデモ）
# 動画と一緒に、READMEに貼るサムネイル（同じ名前の .jpg）も作る。
# vhs組み込みのGIF変換は環境によって無言で失敗するため、vhsにはフレームの書き出しだけをさせ、
# 合成と圧縮はffmpegで行う。必要: vhs, ttyd, ffmpeg(libx264), nvim, gopls
#   例) nix shell nixpkgs#vhs nixpkgs#ttyd nixpkgs#ffmpeg -c scripts/demo/render.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

fps=24
bg=0x1e1e1e
tape=${1:-scripts/demo/demo.tape}
out=${2:-assets/demo.mp4}
poster_at=${POSTER_AT:-12}

rm -rf .demo-frames
vhs "$tape"

size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 .demo-frames/frame-text-00001.png)

# 背景色 → 文字レイヤー → カーソルレイヤーの順に重ね、横1280pxに縮小してH.264で圧縮する。
ffmpeg -y -loglevel error \
	-f lavfi -i "color=c=${bg}:s=${size}:r=${fps}" \
	-framerate "$fps" -i .demo-frames/frame-text-%05d.png \
	-framerate "$fps" -i .demo-frames/frame-cursor-%05d.png \
	-filter_complex "[0][1]overlay=shortest=1[t];[t][2]overlay=shortest=1,scale=1280:-2:flags=lanczos,format=yuv420p" \
	-c:v libx264 -preset slow -crf 28 -tune animation -movflags +faststart -an \
	"$out"

# サムネイル: POSTER_AT 秒目のフレーム
ffmpeg -y -loglevel error -ss "$poster_at" -i "$out" -frames:v 1 -q:v 3 "${out%.mp4}.jpg"

rm -rf .demo-frames
ls -lh "$out" "${out%.mp4}.jpg"
