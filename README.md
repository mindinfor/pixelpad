# PixelPad

PixelPad 是一个用 Swift 和 AppKit 编写的轻量 macOS 图片编辑器。当前界面为简体中文。

- 打开或粘贴图片，添加文字，选择系统字体和字号，导出 PNG。
- 支持像素铅笔、方形像素画笔、平滑圆形画笔、橡皮擦、填充、直线、矩形、椭圆和吸色。
- 支持框选、裁剪、旋转、翻转和调整画布尺寸。画布尺寸可按像素或百分比设置。
- 画布支持触控板缩放，最高 6400%。从 1600% 起显示像素网格。

## 下载

在 [Releases](https://github.com/mindinfor/pixelpad/releases/latest) 下载 ZIP，解压后将 PixelPad.app 拖到「应用程序」文件夹。发布包包含 Apple 芯片和 Intel 两种架构，构建目标为 macOS 13 或更新版本。

这个版本使用临时签名，未经过 Apple 公证。若 macOS 拦截下载版，可以按下面的步骤从源码构建。[Apple 的 Mac 应用打开说明](https://support.apple.com/zh-cn/102445)

## 从源码构建

需要安装 Xcode 命令行工具（可运行 `xcode-select --install`）。

```sh
git clone https://github.com/mindinfor/pixelpad.git
cd pixelpad
./build.sh
open dist/PixelPad.app
```

## 许可证

采用 [MIT 许可证](LICENSE)。
