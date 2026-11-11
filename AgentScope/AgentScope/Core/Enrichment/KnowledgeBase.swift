import Foundation

public struct KnowledgeEntry: Sendable {
    public enum Matcher: Sendable {
        /// Prefix of a label / bundle id / file name (case-insensitive).
        case identifier(String)
        /// Code-signing Team ID.
        case team(String)
        /// Substring of the program, configuration or owner-app path (case-insensitive).
        case path(String)
    }

    public let matchers: [Matcher]
    public let product: String
    public let purpose: PurposeCategory
    public let summary: String
    /// Bundle ids of the app this item serves; used to tell whether it is a leftover.
    public let appBundleIDs: [String]

    public init(
        _ matchers: [Matcher],
        product: String,
        purpose: PurposeCategory,
        summary: String,
        apps: [String] = []
    ) {
        self.matchers = matchers
        self.product = product
        self.purpose = purpose
        self.summary = summary
        self.appBundleIDs = apps
    }
}

public struct KnowledgeBase: Sendable {
    public let entries: [KnowledgeEntry]

    public init(entries: [KnowledgeEntry] = KnowledgeBase.builtIn) {
        self.entries = entries
    }

    /// Returns the most specific entry: longest identifier/path match wins, Team ID counts as a weak match.
    public func match(_ item: ServiceItem) -> KnowledgeEntry? {
        let identifiers = Self.identifiers(of: item)
        let paths = [item.programPath, item.configurationPath, item.ownerAppPath]
            .compactMap { $0?.lowercased() }
        let teamID = item.signing?.teamID

        var best: (score: Int, entry: KnowledgeEntry)?
        for entry in entries {
            var score = 0
            for matcher in entry.matchers {
                switch matcher {
                case .identifier(let prefix):
                    let needle = prefix.lowercased()
                    if identifiers.contains(where: { $0.hasPrefix(needle) }) {
                        score = max(score, 10 + needle.count)
                    }
                case .team(let team):
                    if team == teamID { score = max(score, 5) }
                case .path(let fragment):
                    let needle = fragment.lowercased()
                    if paths.contains(where: { $0.contains(needle) }) {
                        score = max(score, 8 + needle.count)
                    }
                }
            }
            if score > 0, score > (best?.score ?? 0) {
                best = (score, entry)
            }
        }
        return best?.entry
    }

    static func identifiers(of item: ServiceItem) -> [String] {
        var values = [item.label, item.bundleIdentifier, item.name]
        for path in [item.programPath, item.configurationPath] {
            guard let path else { continue }
            values.append(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        }
        return values.compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
    }
}

public extension KnowledgeBase {
    static let builtIn: [KnowledgeEntry] = [
        // MARK: 远程控制
        KnowledgeEntry([.identifier("com.youqu.todesk"), .team("KM56KD59W4"), .path("/ToDesk.app")],
                       product: "ToDesk", purpose: .remoteControl,
                       summary: "ToDesk 远程桌面的服务与会话组件，开机常驻以便随时被远程连接。不需要被远程协助时可在 ToDesk 设置中关闭开机自启。",
                       apps: ["com.youqu.todesk.mac"]),
        KnowledgeEntry([.identifier("com.youqu.todesk.uninstaller")],
                       product: "ToDesk", purpose: .remoteControl,
                       summary: "ToDesk 的卸载辅助，监视主程序是否被删除以便清理残留；平时不运行。",
                       apps: ["com.youqu.todesk.mac"]),
        KnowledgeEntry([.identifier("com.carriez.rustdesk"), .team("HZF9JMC8YN"), .path("/RustDesk.app")],
                       product: "RustDesk", purpose: .remoteControl,
                       summary: "开源远程桌面 RustDesk 的服务端，常驻等待远程连接。",
                       apps: ["com.carriez.rustdesk"]),
        KnowledgeEntry([.identifier("com.teamviewer"), .team("H7UGFBUGV6")],
                       product: "TeamViewer", purpose: .remoteControl,
                       summary: "TeamViewer 的特权助手（安装、授权、卸载用），按需启动。若已不用 TeamViewer，属于残留。",
                       apps: ["com.teamviewer.TeamViewer"]),
        KnowledgeEntry([.team("CPQQ3AW49Y"), .identifier("SRX")],
                       product: "Splashtop", purpose: .remoteControl,
                       summary: "Splashtop 远程桌面的虚拟显示驱动（内核扩展），远程时用于模拟显示器；Apple 芯片默认不加载。",
                       apps: ["com.splashtop.Splashtop-Streamer", "com.splashtop.SplashtopBusiness"]),

        // MARK: 网银 / U 盾
        KnowledgeEntry([.identifier("com.ft_ccb"), .identifier("com.ft_icbc")],
                       product: "飞天诚信 U 盾", purpose: .bankingSecurity,
                       summary: "飞天诚信 U 盾的令牌服务（建设银行 / 工商银行网银），插 U 盾登录网银时需要，常驻后台。"),
        KnowledgeEntry([.team("S47T4UESP3"), .identifier("FTSIP"), .identifier("InterPass")],
                       product: "飞天诚信 U 盾", purpose: .bankingSecurity,
                       summary: "飞天诚信 U 盾的 USB 驱动（内核扩展）；新系统多数 U 盾已改用免驱方式，该驱动通常不再加载。"),
        KnowledgeEntry([.identifier("com.watchdata"), .team("6DN7GZ678J"), .identifier("WDCCB"), .identifier("wdcboc")],
                       product: "握奇 U 盾（建行）", purpose: .bankingSecurity,
                       summary: "握奇数据为建设银行网银 U 盾提供的证书管理与监控服务。"),
        KnowledgeEntry([.identifier("com.tendyron"), .team("2VFG6LEJ44"), .identifier("OnKey")],
                       product: "天地融 U 盾", purpose: .bankingSecurity,
                       summary: "天地融网银 U 盾（建行 / 工行）的插拔监控与驱动，用于网银签名。"),
        KnowledgeEntry([.identifier("com.bhz.hdzbccb"), .team("8A9ZVQ5X7L"), .identifier("HDZB")],
                       product: "华大智宝 U 盾（建行）", purpose: .bankingSecurity,
                       summary: "华大智宝建设银行 U 盾的监控服务与驱动。"),
        KnowledgeEntry([.team("WKT6RZ3WSM"), .identifier("DMeSafe")],
                       product: "大明五洲 U 盾（建行）", purpose: .bankingSecurity,
                       summary: "大明五洲建设银行 U 盾的 USB 驱动（内核扩展），新系统通常不加载。"),
        KnowledgeEntry([.team("5QZKZTWHM6")],
                       product: "文鼎创 U 盾", purpose: .bankingSecurity,
                       summary: "文鼎创（Excelsecu）网银 U 盾的光盘介质驱动（内核扩展），新系统通常不加载。"),
        KnowledgeEntry([.identifier("com.alipay"), .team("BPM6A296T5")],
                       product: "支付宝安全控件", purpose: .bankingSecurity,
                       summary: "支付宝 / 网银网页安全控件的后台服务，浏览器里做支付和网银操作时使用。"),

        // MARK: 自动更新
        KnowledgeEntry([.identifier("com.google.googleupdater"), .identifier("com.google.keystone")],
                       product: "Google 更新器", purpose: .updater,
                       summary: "Google 软件（Chrome 等）的自动更新程序，定时唤醒检查更新。"),
        KnowledgeEntry([.identifier("com.microsoft.update"), .identifier("com.microsoft.autoupdate")],
                       product: "Microsoft AutoUpdate", purpose: .updater,
                       summary: "微软 Office / Edge 等软件的自动更新服务。",
                       apps: ["com.microsoft.autoupdate2"]),
        KnowledgeEntry([.identifier("com.microsoft.office.licensing")],
                       product: "Microsoft Office", purpose: .productivity,
                       summary: "Office 许可证验证用的特权助手。没有 launchd 配置引用时说明 Office 已卸载或已换新版，属于残留。",
                       apps: ["com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint"]),
        KnowledgeEntry([.identifier("com.adobe.armdc"), .identifier("com.adobe.ARMDCHelper")],
                       product: "Adobe Acrobat 更新器", purpose: .updater,
                       summary: "Adobe Acrobat / Reader 的后台更新组件（ARM），定时检查并安装更新。",
                       apps: ["com.adobe.Reader", "com.adobe.Acrobat.Pro"]),
        KnowledgeEntry([.identifier("com.adobe.fpsaud")],
                       product: "Adobe Flash Player", purpose: .updater,
                       summary: "Flash Player 的自动更新守护进程。Flash 已于 2020 年停止支持，这是可以清理的残留。"),
        KnowledgeEntry([.path("org.sparkle-project.Sparkle")],
                       product: "Sparkle 更新器", purpose: .updater,
                       summary: "第三方应用常用的 Sparkle 自动更新进程，应用检查或安装更新时临时运行。"),

        // MARK: 代理 / VPN / 网络
        KnowledgeEntry([.identifier("party.mihomo"), .team("489PDK5LP3")],
                       product: "Mihomo Party", purpose: .proxyVPN,
                       summary: "Mihomo Party 代理客户端的特权助手，用于开启系统代理 / TUN 模式。"),
        KnowledgeEntry([.identifier("com.west2online.clashx"), .team("MEWHFZ92DY")],
                       product: "ClashX", purpose: .proxyVPN,
                       summary: "ClashX 用来修改系统代理设置的特权助手。",
                       apps: ["com.west2online.ClashX", "com.west2online.ClashXPro"]),
        KnowledgeEntry([.identifier("io.tailscale"), .team("W5364U7YZB"), .path("/Tailscale.app")],
                       product: "Tailscale", purpose: .proxyVPN,
                       summary: "Tailscale 组网 VPN 的网络扩展与登录助手。",
                       apps: ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]),
        KnowledgeEntry([.identifier("io.nekohasekai"), .team("287TTNZF8L"), .identifier("sing-box")],
                       product: "sing-box", purpose: .proxyVPN,
                       summary: "sing-box 代理的网络扩展 / 服务，用于全局代理（TUN）。"),
        KnowledgeEntry([.identifier("cloud.oneoh"), .team("GN2W3N34TM")],
                       product: "OneBox", purpose: .proxyVPN,
                       summary: "OneOh Cloud 出品的 OneBox 客户端特权助手，用于修改网络设置。"),
        KnowledgeEntry([.identifier("ddns-go")],
                       product: "ddns-go", purpose: .proxyVPN,
                       summary: "动态 DNS 服务，定期把本机公网 IP 更新到域名解析上。"),
        KnowledgeEntry([.identifier("unbound")],
                       product: "Unbound", purpose: .proxyVPN,
                       summary: "Unbound 本地 DNS 解析服务（Homebrew 安装）。"),
        KnowledgeEntry([.path("/SakuraLauncher.app"), .team("C78T4CMK47")],
                       product: "SakuraFrp", purpose: .proxyVPN,
                       summary: "SakuraFrp 内网穿透启动器的开机助手，用于自动启动穿透隧道。"),

        // MARK: 开发工具
        KnowledgeEntry([.identifier("com.docker"), .team("9BNSXJN65R"), .path("/Docker.app")],
                       product: "Docker Desktop", purpose: .devTools,
                       summary: "Docker Desktop 的后台组件（虚拟网络、Socket 转发、主程序）。",
                       apps: ["com.docker.docker"]),
        KnowledgeEntry([.identifier("de.beyondco.herd"), .team("8Z259RPWAC")],
                       product: "Laravel Herd", purpose: .devTools,
                       summary: "Laravel Herd（PHP 本地开发环境）的特权助手，用于管理本地域名和服务。",
                       apps: ["de.beyondco.herd"]),
        KnowledgeEntry([.identifier("org.xquartz"), .team("NA574AWV7E")],
                       product: "XQuartz", purpose: .devTools,
                       summary: "XQuartz（X11 图形环境）的启动服务，只有运行 X11 程序时才需要。",
                       apps: ["org.xquartz.X11", "org.macosforge.xquartz.X11"]),
        KnowledgeEntry([.identifier("org.virtualbox")],
                       product: "VirtualBox", purpose: .devTools,
                       summary: "VirtualBox 虚拟机的开机启动项（加载驱动）。",
                       apps: ["org.virtualbox.app.VirtualBox"]),
        KnowledgeEntry([.identifier("homebrew.mxcl.ollama"), .identifier("ollama")],
                       product: "Ollama", purpose: .devTools,
                       summary: "Ollama 本地大模型服务（Homebrew 安装），常驻提供本地模型 API。"),
        KnowledgeEntry([.identifier("sh.brew.gitea-runner"), .identifier("gitea-runner")],
                       product: "Gitea Runner", purpose: .devTools,
                       summary: "Gitea Actions 的 CI 执行器（Homebrew 安装），从 Gitea 拉取并运行流水线任务。"),
        KnowledgeEntry([.identifier("gpg-agent")],
                       product: "GnuPG", purpose: .devTools,
                       summary: "GPG 密钥代理，缓存签名 / 解密用的私钥口令，由 git 签名或 gpg 命令按需拉起。"),
        KnowledgeEntry([.path("/cmux/"), .identifier("com.cmuxterm")],
                       product: "cmux", purpose: .devTools,
                       summary: "cmux 终端的后台辅助进程。"),
        KnowledgeEntry([.path("/orca/daemon-host/")],
                       product: "Orca", purpose: .devTools,
                       summary: "Orca 的终端宿主守护进程，保持工作树终端会话在后台运行。"),
        KnowledgeEntry([.team("Q6L2SF6YDW"), .path("/Claude.app")],
                       product: "Claude", purpose: .productivity,
                       summary: "Anthropic Claude 桌面客户端，登录时自动打开。"),
        KnowledgeEntry([.path("/CodexBar.app"), .identifier("com.steipete.codexbar")],
                       product: "CodexBar", purpose: .devTools,
                       summary: "菜单栏显示 Codex / Claude 用量的小工具。"),

        // MARK: 同步 / 备份 / 网盘
        KnowledgeEntry([.identifier("com.synology")],
                       product: "Synology Drive", purpose: .syncBackup,
                       summary: "群晖 Synology Drive 同步客户端及其 Finder 刷新插件。",
                       apps: ["com.synology.SynologyDrive"]),
        KnowledgeEntry([.identifier("飞牛"), .team("ZY78T3Q4DK")],
                       product: "飞牛同步", purpose: .syncBackup,
                       summary: "飞牛 fnOS NAS 的文件同步客户端，开机常驻同步。"),
        KnowledgeEntry([.path("/Nutstore.app"), .team("MZ8SP3X9CP")],
                       product: "坚果云", purpose: .syncBackup,
                       summary: "坚果云同步客户端，后台常驻同步文件。"),
        KnowledgeEntry([.identifier("com.baidu.netdisk")],
                       product: "百度网盘", purpose: .syncBackup,
                       summary: "百度网盘安装 Finder 扩展时使用的一次性特权助手，没有 launchd 配置引用，平时不会运行。",
                       apps: ["com.baidu.netdisk", "com.baidu.BaiduNetdisk-mac"]),

        // MARK: 安全 / 清理
        KnowledgeEntry([.identifier("com.tencent.lemon"), .team("88L2Q4487U")],
                       product: "腾讯柠檬清理", purpose: .securityCleaner,
                       summary: "腾讯柠檬清理的守护进程、状态栏监控和废纸篓监听组件。",
                       apps: ["com.tencent.Lemon"]),

        // MARK: 硬件 / 驱动 / 设备互联
        KnowledgeEntry([.identifier("com.crystalidea.macsfancontrol"), .team("ACC5R6RH47")],
                       product: "Macs Fan Control", purpose: .peripheralDriver,
                       summary: "Macs Fan Control 写入风扇转速用的特权助手。",
                       apps: ["com.crystalidea.macsfancontrol"]),
        KnowledgeEntry([.identifier("com.oplus.dsp"), .team("4UW83339V3")],
                       product: "OPPO 互联", purpose: .peripheralDriver,
                       summary: "OPPO / 一加（欢太）手机与电脑互联、投屏的服务组件。"),
        KnowledgeEntry([.identifier("com.boegam.eshow")],
                       product: "必捷投屏", purpose: .peripheralDriver,
                       summary: "必捷（eShow）无线投屏的后台服务，用于把电脑画面投到会议大屏。"),
        KnowledgeEntry([.identifier("com.cvte"), .team("2ZNMX3X6V3")],
                       product: "希沃 / CVTE 投屏", purpose: .peripheralDriver,
                       summary: "视源（CVTE / 希沃）无线投屏传屏服务，用于连接会议平板。"),
        KnowledgeEntry([.team("6HB5Y2QTA3")],
                       product: "HP 打印机驱动", purpose: .peripheralDriver,
                       summary: "HP 打印机 / 传真的旧式 USB 驱动（内核扩展），现代 macOS 打印通常无需加载。"),
        KnowledgeEntry([.team("EWX3D298F8")],
                       product: "炬力 USB 显示 / 音频驱动", purpose: .peripheralDriver,
                       summary: "炬力（Actions）USB 投屏器 / 音频设备的驱动（内核扩展），Apple 芯片默认不加载。"),
        KnowledgeEntry([.identifier("com.joshuawise"), .identifier("HoRNDIS")],
                       product: "HoRNDIS", purpose: .peripheralDriver,
                       summary: "安卓手机 USB 网络共享驱动（内核扩展），未签名且 Apple 芯片不加载，多为旧驱动残留。"),
        KnowledgeEntry([.team("Q9P8K45M5C"), .identifier("SoftRAID")],
                       product: "SoftRAID", purpose: .peripheralDriver,
                       summary: "OWC SoftRAID 磁盘阵列驱动（内核扩展）。不使用 SoftRAID 阵列时不需要。"),
        KnowledgeEntry([.identifier("com.battery")],
                       product: "Battery", purpose: .peripheralDriver,
                       summary: "电池充电管理工具（限制充电上限）的后台进程。"),

        // MARK: 通讯 / 会议
        KnowledgeEntry([.identifier("us.zoom"), .team("BJ4HAAB9B3")],
                       product: "Zoom", purpose: .communication,
                       summary: "Zoom 会议客户端的守护进程（安装更新、音频驱动）。",
                       apps: ["us.zoom.xos"]),

        // MARK: 办公 / 效率
        KnowledgeEntry([.path("/wpsoffice.app"), .team("2G98R5QYU5")],
                       product: "WPS Office", purpose: .productivity,
                       summary: "WPS Office 的后台组件（最近文件小组件等）。"),
        KnowledgeEntry([.team("4K6FWZU8C4")],
                       product: "Better 系列效率工具", purpose: .productivity,
                       summary: "BetterAndBetter / iCopy / iRightMouse 等效率工具，常驻菜单栏提供快捷操作。"),
        KnowledgeEntry([.path("/PixPin.app"), .team("N6RUM69A6S")],
                       product: "PixPin", purpose: .productivity,
                       summary: "PixPin 截图 / 贴图工具，常驻菜单栏。"),
        KnowledgeEntry([.path("/Mos.app")],
                       product: "Mos", purpose: .productivity,
                       summary: "Mos 鼠标平滑滚动工具，常驻菜单栏。"),
        KnowledgeEntry([.path("/TypeWhisper.app")],
                       product: "TypeWhisper", purpose: .productivity,
                       summary: "TypeWhisper 语音转文字输入工具，常驻菜单栏。"),
        KnowledgeEntry([.path("/PicGo.app")],
                       product: "PicGo", purpose: .productivity,
                       summary: "PicGo 图床上传工具，常驻菜单栏。"),
        KnowledgeEntry([.path("/LaunchNext.app")],
                       product: "LaunchNext", purpose: .productivity,
                       summary: "LaunchNext 启动台替代工具。"),
        KnowledgeEntry([.path("/UnzipOne.app")],
                       product: "UnzipOne", purpose: .productivity,
                       summary: "UnzipOne 解压工具的后台进程。"),
        KnowledgeEntry([.path("/Qingg.app"), .team("924UK7R697")],
                       product: "清歌输入法", purpose: .productivity,
                       summary: "清歌五笔输入法，输入法进程会一直常驻。"),
        KnowledgeEntry([.path("/WorkBuddy.app"), .team("FN2V63AD2J")],
                       product: "WorkBuddy", purpose: .productivity,
                       summary: "腾讯 WorkBuddy AI 办公助手的后台进程。"),
        KnowledgeEntry([.path("/VideoFusion-macOS.app"), .team("X2JNK7LY8J")],
                       product: "VideoFusion", purpose: .productivity,
                       summary: "VideoFusion 视频工具的托盘助手（应用内置登录项）。"),
        KnowledgeEntry([.path("/Tot.app"), .identifier("com.iconfactory.tot")],
                       product: "Tot", purpose: .productivity,
                       summary: "Tot 菜单栏便签工具，内置开机自启助手。",
                       apps: ["com.iconfactory.Tot"]),
        KnowledgeEntry([.path("/Enpass.app"), .identifier("in.sinew")],
                       product: "Enpass", purpose: .securityCleaner,
                       summary: "Enpass 密码管理器，内置开机自启助手以便随时自动填充。",
                       apps: ["in.sinew.Enpass-Desktop"]),
        KnowledgeEntry([.path("/Cleaner.app"), .identifier("cn.better365.Cleaner")],
                       product: "Cleaner", purpose: .securityCleaner,
                       summary: "Better365 出品的 Cleaner 清理工具，内置开机助手用于后台监控。",
                       apps: ["cn.better365.Cleaner"]),
        KnowledgeEntry([.path("/O+Connect.app"), .identifier("com.oplus.devicespace")],
                       product: "O+ 互联", purpose: .peripheralDriver,
                       summary: "OPPO / 一加 O+ 互联，手机与电脑互联、远程控制手机的开机助手。",
                       apps: ["com.oplus.devicespace"]),
        KnowledgeEntry([.path("/企业微信.app"), .identifier("com.tencent.WeWork")],
                       product: "企业微信", purpose: .communication,
                       summary: "企业微信客户端的开机助手和进程通信助手。",
                       apps: ["com.tencent.WeWorkMac"]),
        KnowledgeEntry([.path("/QQ.app"), .identifier("com.tencent.qq")],
                       product: "QQ", purpose: .communication,
                       summary: "QQ 客户端的开机自启助手。",
                       apps: ["com.tencent.qq"]),
        KnowledgeEntry([.path("/V2rayU.app"), .identifier("net.yanue")],
                       product: "V2rayU", purpose: .proxyVPN,
                       summary: "V2rayU 代理客户端的开机自启助手。",
                       apps: ["net.yanue.V2rayU"]),
        KnowledgeEntry([.path("/Thunder.app"), .identifier("com.xunlei")],
                       product: "迅雷", purpose: .media,
                       summary: "迅雷下载的开机自启助手。",
                       apps: ["com.xunlei.Thunder"]),
        KnowledgeEntry([.path("/NeteaseMusic.app"), .identifier("com.netease.163music")],
                       product: "网易云音乐", purpose: .media,
                       summary: "网易云音乐的开机自启助手。",
                       apps: ["com.netease.163music"]),
        KnowledgeEntry([.path("/优酷.app"), .identifier("com.youku")],
                       product: "优酷", purpose: .media,
                       summary: "优酷视频客户端的开机自启助手。",
                       apps: ["com.youku.mac"]),
        KnowledgeEntry([.path("/LyricsX.app"), .identifier("ddddxxx.LyricsX")],
                       product: "LyricsX", purpose: .media,
                       summary: "LyricsX 桌面歌词工具的开机自启助手。",
                       apps: ["ddddxxx.LyricsX"]),
        KnowledgeEntry([.path("/每日英语听力.app"), .identifier("com.eusoft")],
                       product: "每日英语听力", purpose: .media,
                       summary: "欧路「每日英语听力」的开机自启助手。",
                       apps: ["com.eusoft.ting-mac-en"]),
        KnowledgeEntry([.path("/BaiduNetdisk.app")],
                       product: "百度网盘", purpose: .syncBackup,
                       summary: "百度网盘客户端的开机自启助手。",
                       apps: ["com.baidu.netdisk"]),
        KnowledgeEntry([.path("/magpie.app"), .team("LY7MVTUDZG")],
                       product: "Magpie", purpose: .productivity,
                       summary: "Magpie 菜单栏工具的后台进程。")
    ]
}
