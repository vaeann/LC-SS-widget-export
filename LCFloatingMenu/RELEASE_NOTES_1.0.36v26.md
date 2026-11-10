# LCFloatingMenu 1.0.36v26

## 修复：自动更新报「更新未完成 / 未在LC私有插件目录找到微珠」

应用内更新原本只认一个精确文件名 `Documents/Tweaks/LCFloatingMenu.dylib`。
只要导入时用的是带版本号的副本（例如 `LCFloatingMenu-1.0.36v25.dylib`），
或者插件在原生 Tweaks 页面被停用（`LCFloatingMenu.dylib.disabled`），
下载和 SHA-256 校验即使全部成功，替换这一步也会直接判定「没找到微珠」，
一个字节都不会写入。

现在改为按二进制内容识别：读取 Mach-O 头并匹配 `LC_ID_DYLIB` 的
`@rpath/LCFloatingMenu.dylib`，文件名可以随便取。

- 规范名 `LCFloatingMenu.dylib` 存在时行为不变，优先替换它。
- 规范名不存在时扫描目录，识别出微珠后原地替换，文件名保持不变。
- 处于停用状态的 `*.dylib.disabled` 会被识别，替换后仍保持停用。
- 目录里有多份副本时全部刷新，避免旧版残留继续被加载。
- 找不到时给出可执行的诊断：目录里有几个 dylib、都叫什么名字、
  或者微珠其实装在共享插件目录 `LiveContainer/Tweaks`。

## 一并加固的两处同名假设

- 插件中心：带版本号文件名下，「为防止微珠管理入口失效，禁止在此停用宿主微珠」
  的保护原本会失效，现在按 `LCFloatingMenu` 家族名匹配。
- 插件审计：日志里「正在运行的微珠」「共享目录里的微珠」比对同样按家族名识别，
  不再因为改了文件名就显示 missing。

## 从 v25 及更早版本升级

这一版本身修的就是更新路径，所以旧版本**没法**自动更新上来。请手动做一次：

1. 从本 Release 下载 `LCFloatingMenu.dylib`（规范名那个资产）。
2. 在 LC 原生 Tweaks 页面删掉旧的微珠，导入新文件并重新签名。
3. 重启 LC 和相关 Guest。

之后文件名是什么都不影响应用内更新。
