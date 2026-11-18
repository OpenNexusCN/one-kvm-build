scrcpy 3.3（aarch64 自编译）产物备份
=====================================

来源：192.168.2.198（one-kvm / Armbian 26.11.0 noble / Ubuntu 24.04 aarch64）
构建：2026-11-18 16:27 CST，gcc 13.3.0 + meson 1.3.2 + ninja，-Dprebuilt_server=官方 scrcpy-server v3.3
用途：给同架构（arm64 Linux）的板子重装 / 换机 / 灾备；Windows 上不能直接运行。

目录内容
--------
  scrcpy                                 264,184 B  aarch64 ELF64 可执行文件（scrcpy 3.3 客户端）
  scrcpy-server                           90,752 B  官方预编译服务端 v3.3（jar/apk 容器，与 3.3 客户端严格配对）
  scrcpy-3.3-aarch64-20261118.tar.gz     762,128 B  完整备份包，内含：
      usr/local/bin/scrcpy                             （安装树的二进制）
      usr/local/share/scrcpy/scrcpy-server             （安装树的服务端）
      doc/scrcpy.1, doc/scrcpy.png, doc/scrcpy        （man 页、图标、bash 补全）
      src/v3.3.tar.gz, src/scrcpy-server-v3.3         （源码与官方服务端原件，可用于重建）
      README.txt, SHA256SUMS                           （板端生成的说明与校验和）

SHA-256（板端生成，已与本地下载件逐一比对一致）
-----------------------------------------------
  4fd97fd1134fd74b01c300e5b5c7f79121f278b719fef1e7fe179dc8692728c9  scrcpy
  351cb2edc7e4c2c75f09a7933fdabcf137be52e2602df154f24ec02db46e9e51  scrcpy-server

校验（Windows PowerShell）
--------------------------
  Get-FileHash .\scrcpy, .\scrcpy-server -Algorithm SHA256 | Format-List
  # 期望与上面两行一致

安装到 arm64 Linux 板子
------------------------
  tar xzf scrcpy-3.3-aarch64-20261118.tar.gz
  install -m 0755 scrcpy-3.3-aarch64/usr/local/bin/scrcpy /usr/local/bin/scrcpy
  install -d /usr/local/share/scrcpy
  install -m 0644 scrcpy-3.3-aarch64/usr/local/share/scrcpy/scrcpy-server /usr/local/share/scrcpy/scrcpy-server
  # 可选：man / 图标 / 补全
  install -D -m 0644 scrcpy-3.3-aarch64/doc/scrcpy.1  /usr/local/share/man/man1/scrcpy.1
  install -D -m 0644 scrcpy-3.3-aarch64/doc/scrcpy.png /usr/local/share/icons/hicolor/256x256/apps/scrcpy.png
  install -D -m 0644 scrcpy-3.3-aarch64/doc/scrcpy    /usr/local/share/bash-completion/completions/scrcpy

运行依赖（Debian/Ubuntu arm64）
-------------------------------
  apt-get install -y libsdl2-2.0-0 libavcodec60 libavformat60 libavutil58 \
                     libavdevice60 libswresample4 libusb-1.0-0
  # 若自行编译（而非恢复本备份），还需要：meson ninja-build pkg-config gcc
  #   libsdl2-dev libavcodec-dev libavformat-dev libavutil-dev libavdevice-dev \
  #   libswresample-dev libusb-1.0-0-dev

用法
----
  # 无显示器（本机没有 X/Wayland）——录制成文件
  scrcpy --no-playback --stay-awake --max-size=1024 --record=/tmp/rec.mp4
  # 只要视频不要声音
  scrcpy --no-playback --no-audio --record=/tmp/rec.mp4
  # 容器更抗断线
  scrcpy --no-playback --record-format=mkv --record=/tmp/rec.mkv
  # 停止：Ctrl-C 或 kill -TERM <pid>（会写完整 mp4 尾部）
  # 指定服务端（不装到 /usr/local 时）：
  SCRCPY_SERVER_PATH=/path/to/scrcpy-server scrcpy --no-playback --record=/tmp/rec.mp4
  # 有桌面的机器上（实时窗口投屏）：直接 scrcpy，或用 --adb 指向远端 adb server

重建（如需换版本）
------------------
  tar xf src/v3.3.tar.gz
  meson setup build --buildtype=release --strip -Dprebuilt_server=$PWD/src/scrcpy-server-v3.3
  ninja -C build && ninja -C build install

备忘
----
  * Ubuntu noble 自带的 scrcpy 1.25 在 Android 14+（本机 Android 16）上必崩：
    服务端反射 SurfaceControl.createDisplay / IClipboard$Stub$Proxy.addPrimaryClipChangedListener
    抛 NoSuchMethodException，录出 0 字节。必须用 2.x/3.x。
  * Google 官方 platform-tools 没有 linux-arm64 预编译包，arm64 上只能用发行版 adb
    （本机为 adb 34.0.4-debian）或自行编译。
