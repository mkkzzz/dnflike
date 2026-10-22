# DNF 资源共享与工作区接入

## 存储与版本

用户 2026-10-22 验收新版实机演示，并将原先“资源暂不上传”改为允许上传全部资源。
用户进一步指定ws1战斗、ws2完整循环，并要求ws2供应所有相关开发资料；本轮分工/交付责任见[28契约](28_工作区分工与原版资料共享.md)。
完整资源库放在工程外，所有工作区使用同一份版本清单，不把全库加入 Godot 导入范围。
本次授权是项目内资源共享决定，不声明第三方资源的著作权归属发生变化。

| 层级 | 位置 | 作用 |
|---|---|---|
| 源码与锁文件 | 主仓库的 `game_dnf/asset_store.json` | 固定资源版本、分包大小与 SHA256；不保存令牌 |
| 远程完整包 | [独立资源仓库](https://github.com/mkkzzz/dnflike-assets) 的 Releases | 全部已提取资源、索引、来源、动作配置备份与运行包 |
| 同机共享缓存 | Windows 仓库所在盘的 `dnflike-assets/<version>/` | `library_v1/` 是完整库；`runtime/` 是精选运行源与成品 |
| 项目消费副本 | `game_dnf/assets_local/` | 只复制本版运行所需文件，不进入源码 Git |
| 补充原版参考包 | `game_dnf/reference_store.json`锁定的独立Release | 原物品/装备代码表、新手说明原件与来源定位；独立缓存，不改游戏消费副本 |
| 全部来源入口 | `game_dnf/source_materials.json` | 已共享PVF/数据库/声音映射与补充资料的路径/哈希、未知取证项 |

远程资源库采用独立私有仓库；公开源码仓库不等于资源库公开。
Godot 的 `.godot`、`.import` 缓存不进共享包。
全库包含原解包中已记录的异常、未知项和来源差异；共享成功不代表资源完整性缺口已修复。
未加入原客户端可执行文件或服务端目录。

**没有原DNF客户端也可开发**：运行包可启动Godot样板，完整提取库可查图像/动作/配置。ws1具体接入、源码任务边界与首任务见[无原客户端接入任务包](../tasks/design_tasks/ws1_dnf_onboarding_v1.md)；实际原版运行行为仍由具备原环境的工作区补证据。

## 各工作区首次使用

```powershell
# 在自己的 clone 中同步源码后执行；先有可用的 GitHub 登录
python tools/dnf_asset_store.py sync
tools/run_dnf.ps1
# 开发时需要浏览/筛选全库再执行
python tools/dnf_asset_store.py sync --full
# 原版补充说明/代码表；与运行资源锁独立
python tools/sync_dnf_references.py
# 完整库的分类检索、逐帧查看、ANI/配置查询与单个IMG导出（需Pillow）
python tools/browse_dnf_assets.py
```

启动脚本遇到缺少运行资源、版本或包哈希变化时会自动执行小包同步；不会自动下载全库。
全库默认落在缓存根的版本目录，具体路径由命令输出的 LIBRARY 行给出。
同一台机器同一磁盘的多个 clone 会共用外部缓存，跨机器则各下载一份同版本。
不同磁盘的工作区可用下列方式指定同一个根目录：

```powershell
$env:DNFLIKE_ASSET_HOME = "D:/dnflike-assets"
python tools/dnf_asset_store.py sync --full
```

也可在本地 `.workspace` 登记 `dnf_asset_home=D:/dnflike-assets`，该文件不提交。
非 Windows 默认使用用户缓存目录；`--home` 只指定缓存位置，完整库禁止放进当前 checkout。
私有资源库要求账号具备读权限；协作者收到邀请时，需先在 GitHub 接受。
当前为个人名下仓库，GitHub 不提供仅阅读的协作者等级；现有主仓库的写协作者沿用写协作身份。
不将仅有阅读权限的人员自动升级；邀请与已接收状态分开记录。
凭据由本机 Git Credential Manager 或 `GH_TOKEN` / `GITHUB_TOKEN` 提供；不得贴进文档或脚本。
细粒度令牌须包含资源仓库及 Contents 读取权限；只有主源码仓库权限的令牌无法读取私有资源包。

资源浏览器仅监听本机 `http://127.0.0.1:8769/`，不依赖 ws2 的原始 temp 路径。
原库内的启动CMD作为源快照保留；跨区统一使用上面的 `tools/browse_dnf_assets.py` 入口。
沿用完整库已整理的分类索引，可查看原始IMG裁切/偏移与ANI毫秒帧表，音频按原编码播放。
按IMG导出的PNG包保存到外部缓存根的 exports 目录，避免改写不可变版本库。
未能解码的资源会显示错误，保留异常说明，不将其伪装成完整可用素材。

## 校验、冲突与更新

- 下载先核对大小和 SHA256，再核对 ZIP 中的登记路径、长度与每个文件的 SHA256。
- 拒绝绝对路径、越界路径、软链接、未登记成员和已损坏包。
- 外部缓存若已有不同内容，停止并保留原文件；项目升级仅替换安装登记中未被修改的官方文件。
- 项目存在本地改动时，先完成全文件冲突检查再写入；有冲突则保留全部原项目文件，不覆盖其它区成果。
- 只复制包内登记的运行文件，外部缓存中额外添加的文件不会隐式进入项目。
- ZIP 下载成功保留在外部 downloads 目录，后续安装可以复用；网络失败可重新运行。
- 发布版本不可就地改字节；新增或替换资源时发布新版本并更新锁文件。
- 本机命令成功不能代填其它电脑的接收状态；各区首次执行后自行登记接收。

## 重新编译与发布

已同步运行包时，所选 IMG、ANI 元数据和 Ogg 已随包保存，可直接重建图集：

```powershell
python tools/build_dnf_assets.py
```

需要从完整库重新选资源时，把上述 LIBRARY 路径传给 `tools/build_dnf_assets.py --library`。
原 ANI 毫秒时钟、IMG 锚点与选中源哈希保持原契约。

维护者先用 `tools/dnf_asset_store.py pack --help` 创建新版本；完整源与运行源分别登记。
分包保存原字节、UTF-8 路径和每文件哈希；没有重编码音频或重采样图像。
用 `tools/publish_dnf_assets.py --help` 上传到独立仓库 Release，二进制不进入源码提交。
使用[GitHub Release 附件](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)，每个归档限制在2 GiB以下。
发布器核对远端返回的大小与 SHA256，全部确认后才将草稿发布。
完成后再同步主仓库的锁文件、文档与交接记录。

本轮发布快照及验收边界见[共享记录](../reports/ws2/2026-10/2026-10-22_DNF资源共享与验收.md)。
补充资料发布与新分工记录见[本轮交接](../reports/ws2/2026-10/2026-10-22_战斗循环分工与原版资料共享.md)。说明文档和代码表是原整合包参考，可能含定制/后期内容；有效性仍须核实。
