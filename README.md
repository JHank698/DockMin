# DockMin

Windows 式 Dock 切换：点一下 Dock 图标把应用带到前台，**再点一次最小化到 Dock**；
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

取回不受这个开关影响：窗口都收起之后"最前的那个"已经没有意义了。

点后台应用的图标仍然只是正常激活（不收起）；拖拽排序、长按、快速连点都不会误触发。

> ℹ️ 重新编译对两项权限的影响**不一样**，实测（同一个 bundle、同一路径）：
>
> - **辅助功能**：勾选跨重编译存活。新进程启动时日志里可能先报
>   `Failed to match existing code requirement ... kTCCServiceAccessibility` 并连着读到
>   `a11y=false`，实测会在 **75 秒左右**自己恢复 true（不是十几秒）。程序每 3 秒轮询，
>   恢复后自动接上，不用管它。
> - **输入监控**：**重新编译后可能失效，而且不会自己恢复**（实测一直停在 `input=false`，
>   `tap` 因此挂不起来，表现就是"点 Dock 完全没反应"）。tccd 里那条记录绑的是旧二进制，
>   面板却仍显示勾选。处理：到「系统设置 → 隐私与安全 → 输入监控」重新勾选（列表里
>   没有就用 `+` 添加 `build/DockMin.app`），勾完**不用重启 app**，轮询会在 3 秒内把
>   tap 挂上（日志出现 `tap=true`）。
>   ⚠️ 别用 `tccutil reset ListenEvent` 图省事：它只是删掉一条授权，删完照样得手动重勾，
>   实测对恢复没有帮助（脚本里曾经自动做这件事，已撤掉）。
>
> 一劳永逸的办法是换一个稳定的自签名证书（钥匙串访问 → 证书助理 → 创建证书，类型选
> 「代码签名」），让签名不再变：
> ```bash
> SIGN_IDENTITY="你的证书名" ./Scripts/make-app.sh --run
> ```

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

## 排查

同一个二进制自带诊断模式，不用点鼠标就能确认状态：

```bash
./Scripts/make-app.sh --status      # 权限 / Dock 进程 / 登录项，就绪返回 0
./Scripts/make-app.sh --dump-dock   # 命中测试能看到的所有 Dock 图块
./Scripts/make-app.sh --hit 123 1080  # 某个坐标会落到哪个应用
```

`--dump-dock` 输出为空 = 辅助功能没生效；`--hit` 打在图标上却是 `no app` =
标题匹配没对上（Dock 显示名和应用名不一致）。

**`--status` 的读数不能当作 app 实例的证据。** 从 shell 里跑同一个二进制时，TCC 把这次
调用归属到宿主的终端 App，而不是 bundle 自己——实测同一时刻：app 实例的统一日志报
`a11y=true`，shell 里 `--status` 报 `NOT granted`。要看真实状态，查 app 实例自己打的日志：

```bash
/usr/bin/log show --last 5m --predicate 'process == "DockMin" AND subsystem == "com.local.dockmin"'
```

输出形如 `a11y=true input=false tap=false frontOnly=false`。启动后十几秒内
`a11y` 可能是 false，等它自己变 true（菜单里那两行「已授权 / 未授权」也是同一份状态）。

**点击完全没反应** = `tap=false`。先确认进程在跑（`pgrep -fl DockMin`）——重新构建后用
`open build/DockMin.app` 可能只是把**旧进程**唤醒，`./Scripts/make-app.sh --run` 会先杀再起。
再看是不是 `input=false`：到系统设置里重新勾选输入监控（见上面「构建 & 运行」那条）。

`tap=true` 但点击无效，才去看命中测试和基线判断——`click …` 那几行日志会告诉你程序
认为这次点击是 `minimize` 还是 `restore`（`restore 0 (Dock already did it)` 是正常结果，
说明窗口是 Dock 自己恢复的，我们只是没有再去最小化）。

## 原理

- `CGEventTap`（listen-only）监听全局鼠标按下/抬起 → 需要输入监控权限
- `Accessibility API`（`AXUIElement`）把点击坐标命中到具体应用、用 `kAXMinimizedAttribute`
  最小化 / 还原窗口 → 需要辅助功能权限，且应用必须**非沙盒**
- 以「鼠标按下时的最前应用」为基线区分「点已激活 → 收起」与「点后台 → 正常激活」，避免误判
- **收起 / 取回的判断不能等到鼠标抬起**：Dock 在按下那一刻就已经把最小化的窗口恢复了，
  到抬起时"有可见窗口"两种情况长得一模一样。所以：按下时先读一次被点图标的窗口状态做快照，
  抬起时只负责执行；并且记一笔「上一个被我们收起的应用」——这个是我们自己做过的事实，
  比任何 AX 读取都确定，按下快照被 Dock 抢跑时由它兜住。
  （早期版本在抬起时才读状态，第三次点击就变成了「显示后立刻又最小化」。）
- Dock 内部的角色/层级没有文档且跨版本会变，所以命中测试不依赖角色名：遍历整棵树取
  「有标题 + 有 frame」的元素，用几何关系判定——单个图标的 frame 永远小于它所在的列表
- 只处理真正的单击（按下/抬起位移 < 8pt、时长 < 0.6s），拖拽排序、长按不会误触发

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

