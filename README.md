# モデル学習がOOM Killerに殺されブチ切れた方へ

![](https://raw.githubusercontent.com/yKesamaru/oom_killer/main/assets/eye-catch.png)

## はじめに
`OOM Killer`とは、Linuxにおいてメモリ不足に陥った際に、**メモリを消費しているプロセスを殺すことで、メモリを確保する仕組み**です。しかしその決定は動的に行われるので、[単純ではありません](https://github.com/lorenzo-stoakes/linux-vm-notes/blob/master/sections/oom.md#out_of_memory)。

以下の式は単純化したものです。詳しくは下記「わかりやすい参照」を確認してください。

> $メモリ使用率(‰) = \frac{x}{\text{RAM} + \text{swap}} \times 1000$
> 
> - `x` : プロセスが使用しているメモリ量
> - `RAM` : システムの物理メモリ量
> - `swap` : スワップ領域のサイズ


Ubuntu 20.04 LTS使用時には遭遇しなかった`OOM Killer`が、Ubuntu 22.04 LTSにアップグレードしたとたん遭遇しました。

モデル学習中に`OOM Killer`によってプロセスが殺されてしまい、モデル学習が中断されてしまいました。（2度も！）

悪いことに、モデル学習は一度ストップしてしまうと、チェックポイントからの再開時に大幅なロス値増加が発生します。（わたしの場合、必ずそうなります）

![](https://raw.githubusercontent.com/yKesamaru/oom_killer/main/assets/2023-12-17-15-00-13.png)

これでは非常に困ります。

`OOM Killer`のアルゴリズムはカーネルのバージョンによって進化するようで、今回はその変更されたアルゴリズムに引っかかってしまったのだと思います。

### わかりやすい参照
- [その51 プロセスを殺戮する恐怖のOOM killer](https://www.youtube.com/watch?app=desktop&v=D13PVCaHnk0)
- [Linuxにおけるメモリ管理機構の利用に関する覚え書き](https://kmyk.github.io/blog/blog/2016/12/31/linux-memory-management/)
- [LinuxにおけるOOM発生時の挙動](https://zenn.dev/satoru_takeuchi/articles/bdbdeceea00a2888c580#memory-cgourp%E3%81%AE%E5%A0%B4%E5%90%88)

### より詳細な参照
- [Out of Memory Killer](https://github.com/lorenzo-stoakes/linux-vm-notes/blob/master/sections/oom.md)
- [Memory Resource Controller](https://docs.kernel.org/admin-guide/cgroup-v1/memory.html?highlight=oom)
- [Concepts overview](https://docs.kernel.org/6.2/admin-guide/mm/concepts.html)

## エラーログの確認
```bash
$ journalctl --since today
# あるいは
$ journalctl -xe
# あるいは
$ journalctl --since "09:30"
```

```log
12月 17 10:04:41 user systemd-oomd[588]: Killed /user.slice/user-1000.slice/user@1000.service/app.slice/app-org.gnome.Terminal.slice/vte-spawn-f6518140-41fe-4a13-b828-55c5b8738fb8.scope due to memory pressure for /user.slice/user-1000.slice/user@1000.service being 57.97% > 50.00% for > 20s with reclaim activity
12月 17 10:04:42 user systemd[1565]: vte-spawn-f6518140-41fe-4a13-b828-55c5b8738fb8.scope: systemd-oomd killed 3 process(es) in this unit.
```

はい、ばっちり`killed`されているのが確認できました。

## 方針
そもそもメモリ不足によるシステムの不安定化を防ぐために、`OOM Killer`は存在しています。なので、メモリ不足に陥らないようにすることが最善の策です。（主メモリを増設する、とか）

しかしながら今回のログを見る限り、メモリ使用率が`50%`を超えて（57.97%）から`20s`経過した後`OOM Killer`が動作したようです。
主メモリは32GBあり、57%の使用が20s続いてもメモリ不足に陥ることはないはずです。
（その他のプロセスやキャッシュなどがメモリを消費しているとは思いますが、それでもメモリ不足に陥るほどではないです。）


そこで以降では、モデル学習しているプログラムが`OOM Killer`に殺されないようにする方法を考えます。
ただしカーネルパラメータは変更しないものとします。すなわち以下の項目には触りません。
スコアリングシステム自体は、システムの安定性を維持するために必要だからです。
- `/etc/sysctl.conf`ファイルや`/proc/sys/vm/`ディレクトリ内のファイルを通じて設定できるもの
  - `/proc/sys/vm/overcommit_memory`
  - `/proc/sys/vm/overcommit_ratio`
  - `/proc/sys/vm/oom_kill_allocating_task`
  - `/proc/sys/vm/panic_on_oom`
  - `/proc/sys/vm/vm.swappiness`
  - etc...

かわりに、`/procシステム`を編集します。

## 設定の調整
システムの設定や特定のプロセスの`/proc/<pid>/oom_score_adj`を上書きすることで、OOMキラーの挙動を変更することが可能です。
`oom_score_adj`はOOMスコアに直接加算されます。この値は`-1000`から`+1000`の範囲で設定でき、`-1000`に設定するとプロセスはOOMキラーの対象から除外されます。（くわしくは参照にある[Out of Memory Killer](https://github.com/lorenzo-stoakes/linux-vm-notes/blob/master/sections/oom.md)を確認してください。）

さて、`<pid>`を特定する必要が出てきました。

## 専用スクリプトの作成

https://github.com/yKesamaru/oom_killer/blob/96ecd7a370b888ac8e99333c824d353b92ea55ec/my_28.sh#L1-L14

このスクリプトを実行する前に、スクリプトを`sudo`で実行してください。例えば、次のように実行します。

```bash
$ sudo ./my_28.sh
```

このスクリプトを実行した後、新しいターミナルを開いて以下のコマンドを使用します。

```bash
$ tail -f my_28_output.log
```

これにより、`my_28.py`の実行中に出力されるすべてのログを見ることができます。また、`my_28_output.log`ファイルは、プログラムの実行が終了した後もログを確認するための記録として残ります。

## 結果

```bash
user@user:~/bin/pytorch-metric-learning$ bash my_28.sh
PID: 1053421
[sudo] user のパスワード: 
-1000
user@user:~/bin/pytorch-metric-learning$ tail -f my_28_output.log 
Epoch 138/600:   8%|▊         | 151/1909 [00:46<07:57,  3.68it/s, loss=11.6]
```

正常に動作します。

`/proc`ディレクトリ内のファイルも確認します。

![](https://raw.githubusercontent.com/yKesamaru/oom_killer/main/assets/2023-12-17-16-26-32.png)

![](https://raw.githubusercontent.com/yKesamaru/oom_killer/main/assets/2023-12-17-16-27-10.png)

`oom_score_adj`が`-1000`に設定されていることが確認できました。

これでモデル学習中に`OOM Killer`に殺されることはなくなりました。

モデル学習がOOM Killerに殺され、親の仇とばかりにブチ切れた方は、ぜひお試しください。
ただし、ご自身で必ず方針を決めてから実行してください。

以上です。ありがとうございました。

https://www.youtube.com/watch?app=desktop&v=D13PVCaHnk0
https://kmyk.github.io/blog/blog/2016/12/31/linux-memory-management/
https://zenn.dev/satoru_takeuchi/articles/bdbdeceea00a2888c580#memory-cgourp%E3%81%AE%E5%A0%B4%E5%90%88
https://github.com/lorenzo-stoakes/linux-vm-notes/blob/master/sections/oom.md
https://docs.kernel.org/admin-guide/cgroup-v1/memory.html?highlight=oom
https://docs.kernel.org/6.2/admin-guide/mm/concepts.html
