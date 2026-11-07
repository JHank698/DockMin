# DockMin

MACOS27实现Windows式Dock切换：点一下 Dock 图标把应用带到前台，**再点一次最小化到 Dock**；
窗口已经全部收起时再点一次则把它们放回来。常驻后台的菜单栏工具，覆盖所有应用。

> **这是一个只给自己用的本机工具**：本地 ad-hoc 签名、非沙盒，不适合提交 App Store；
> 换机器或换安装路径都要重新授权（见下面「构建 & 运行」里的权限说明）。
> 仓库：https://github.com/JHank698/DockMin

## 构建 & 运行

```bash
./Scripts/make-app.sh --run       # 编译 + ad-hoc 签名 + 启动 build/DockMin.app
./Scripts/make-app.sh --install   # 同上，再装到 /Applications/DockMin.app 并从那里启动
```

日常使用建议走 `--install`：路径固定在 `/Applications`，权限记录和登录项都指向同一份，
不会和 `build/` 里的开发副本抢同一次点击。

首次运行需要授权两项系统权限（菜单栏那枚「两个错开矩形」的图标就是它唯一的界面：
正常时用系统默认色，缺授权时变**红色**，鼠标悬停有提示）：

- **辅助功能（Accessibility）** — 读取 Dock 图标坐标、控制窗口最小化
- **输入监控（Input Monitoring）** — 全局监听鼠标点击

授权后按菜单栏「DockMin」查看状态，可选：

- **仅最小化最前窗口**（默认最小化该应用的全部窗口；选项会记住）
- **登录时启动**（默认开启）

### 一个周期里的行为

| 设置 | 收起 | 取回 |
|---|---|---|
| 关（默认） | 一次收起该应用**全部**窗口 | 一次全部放回 |
| 开「仅最小化最前窗口」 | 一次只收起当前那个，连点 N 次把 N 个窗口挨个收进 Dock | 一次放回已收起的**全部** |

点后台应用的图标仍然只是正常激活（不收起）；拖拽排序、长按、快速连点都不会误触发。

## 稳定签名（可选，根治"重编译掉授权"）

ad-hoc 签名的身份就是那段代码哈希，所以每次重新编译都可能让输入监控的记录对不上。换成一张
自签名的代码签名证书后，身份变成"证书 + Bundle ID"，重编译不再影响授权。

建证书这一步要你自己在图形界面里做并输密码，**下面的菜单名称我没有在本机验证过**
（macOS 版本不同措辞会变），只能当指引看：

1. 打开「钥匙串访问」→ 菜单栏「证书助理」→「创建证书…」
2. 名称填 `DockMin Local`，身份类型「自建身份」，证书类型「代码签名」，其余默认 → 创建
3. 用这个身份构建：
   ```bash
   SIGN_IDENTITY="DockMin Local" ./Scripts/make-app.sh --install
   ```
4. 确认签名真的换掉了：
   ```bash
   codesign -dvv /Applications/DockMin.app 2>&1 | grep -E 'Authority|Signature'
   ```
   应看到 `Authority=DockMin Local`，而不再是 `Signature=adhoc`
5. 换身份后的**第一次**运行，两项权限仍要重新勾一次（TCC 记录指向的是新身份）；
   此后重编译就不会再掉了

如果第 4 步显示的还是 `adhoc`，说明 `SIGN_IDENTITY` 里的名字和钥匙串里的证书通用名不完全一致
（`security find-identity -v -p codesigning` 可以列出可用名字的精确写法）。

## 文件结构

```
Sources/DockMin/
├─ main.swift         # NSApplication 入口（LSUIElement 菜单栏应用）+ 诊断模式分流
├─ AppDelegate.swift  # 菜单栏状态项、权限状态、监听调度、收起/还原判定
├─ EventTap.swift     # CGEventTap：全局鼠标 down/up
├─ DockInspector.swift# AX 枚举 Dock 图标 + 点击命中 → 应用
├─ AppMinimizer.swift # AX 最小化 / 还原应用窗口
├─ Permissions.swift  # 辅助功能 + 输入监控 检测/请求
└─ Diagnostics.swift  # --status / --dump-dock / --hit
```

