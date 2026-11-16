# MoonReConform 项目申报书

**项目名称**　MoonReConform · 视频重剪审阅意见迁移与核对  
**团队账号**　123123213weqw  
**交付形式**　MoonBit 库、Node.js 命令行与可复现的验证脚本  
**代码仓库**　[GitHub 上的 MoonReConform](https://github.com/123123213weqw/moon-reconform)

## 问题和使用对象

剪辑师重排、裁剪或复用镜头后，审阅人员在旧版记录的修改位置会失效。遇到同一素材多次出现时，直接套用原时间会把意见挂到错误的镜头。需要反复审片的小型制作团队可用本项目迁移单帧和区间意见，并逐项确认多候选或无匹配的情况。

## 用法和实现

输入前后两版 `.otio` 工程与 JSON 审阅清单。命令 `plan` 将旧意见拆成唯一匹配、多候选、已删除和旧空白四类片段，附源素材帧和目标候选。审核者填入多候选片段的选择，`apply` 将完整解析的意见写为新工程轨道标记，并保留原有数据。缺失片段会使整条意见留待人工处理。

MoonBit 核心按素材索引新镜头，用整数半开区间和端点扫描定位重合范围，保留所有重复候选，不依赖逐帧遍历或视频解码。交换层使用 MoonTimeline 已发布的 OTIO JSON 编解码器。跨版本审阅关联、候选决策和迁移记录由本项目实现。[上游 MoonTimeline](https://github.com/white-bear233/MoonTimeline)

## 复现与边界

仓库运行 `python scripts/verify.py --live-fixture`，可独立逐帧核对 40 对生成的剪辑和 480 条意见。在固定版本的 ElFuente 60 fps 时间线上构造重剪，从 1430 帧改为 1036 帧，5 条意见迁移 3 条并保留 2 条待处理，导出的标记已用官方 OpenTimelineIO 0.18.1 读取核对。[ElFuente 验证素材](https://github.com/darbyjohnston/otio-oc-examples/blob/2cc61d92fb4c45dfc0ef8e80f4b5dd7c0005f25f/ElFuente_4096x2160_60fps_10bit_420.otio)

当前覆盖同整数帧率、单条视频轨道、可识别源素材 URL 的硬切工程，含重排、裁剪、素材重复和轨道空白。变速、转场、嵌套轨道和素材改名超出当前支持范围。
