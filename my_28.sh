#!/bin/bash

# 仮想環境をアクティブにする
source bin/activate

# モデル学習プログラムをバックグラウンドで実行し、出力をファイルにリダイレクトする
nohup python my_28.py > my_28_output.log 2>&1 &
pid=$!

# PIDを表示
echo "PID: $pid"

# OOMスコアを設定
echo -1000 | sudo tee /proc/$pid/oom_score_adj

