# MoonReConform

MoonReConform 将旧版剪辑上的审阅意见迁移到重剪后的 OpenTimelineIO 工程。剪辑师可以追踪一段意见对应的素材帧，确认重复镜头的目标，或者把缺失素材和旧版空白上的意见留待人工处理。

## 安装与运行

命令行使用 MoonBit `0.10.20+65efd5b93` 和 Node.js 22 或更新版本。复核脚本另需 Python 3.10 或更新版本。在仓库根目录运行以下命令。

```sh
moon update
python scripts/verify.py --demo _build/example
moon run cmd/main --target js -- plan _build/example/before.otio _build/example/after.otio _build/example/request.json
moon run cmd/main --target js -- apply _build/example/before.otio _build/example/after.otio _build/example/request.json _build/example/reviewed.otio
```

两条命令都会在标准输出返回 JSON。其中 `notes[].pieces` 记录旧片段、源素材和所有新候选，`held` 记录待处理意见的 ID，`transfers` 记录可写入的片段，`carry` 把留待处理的意见改写成下一次请求可以直接使用的源素材意见。示例请求包含两项已确认的候选，最终写入五段标记，保留两条待处理意见。重新运行示例时给生成目录和目标 OTIO 选择新路径。

## 审阅请求

```json
{
  "fps": 24,
  "old_track": 0,
  "new_track": 1,
  "notes": [
    {"id": "n1", "text": "检查对白入点", "start": 4},
    {"id": "n2", "text": "核对转场前的字幕", "start": 3, "stop": 6}
  ],
  "selections": [
    {"note_id": "n1", "piece": 0, "clip": 3}
  ]
}
```

- `old_track` 和 `new_track` 是各工程 `tracks.children` 中从零开始的索引。时间以所选轨道第一帧为 0，各端点为帧号。区间为 `[start, stop)`，省略 `stop` 表示单帧。
- 请求、单条意见和人工确认里的未知字段按名拒绝。例如把 `stop` 写成 `end` 会返回 `annotation n1: unknown field end`，不会把区间意见悄悄当作单帧意见。OTIO 工程自身的未知字段不受影响，原样保留。
- 从 `plan` 的报告确认 `ambiguous` 片段的候选，将选中的 `clip` 和该片段在 `pieces` 中的索引加入 `selections`，再用同一对 OTIO 文件执行 `apply`。新轨道中空白也占用子项索引。
- `unique` 表示恰有一个新位置，`ambiguous` 表示两个以上，`deleted` 表示没有新位置，`gap` 表示旧位置处于轨道空白。只有一条意见的全部片段解析完毕才会生成标记。有些意见会拆成数个标记，原 ID 和片段序号保存在 `metadata.moon_reconform`。
- 意见也可以锚定在源素材上：给出 `media`（素材 URL）和 `source`（素材帧区间），不给出 `start` 与 `stop`，例如 `{"id": "c1", "text": "核对片头", "media": "file:///shoot/A.mov", "source": {"start": 30, "stop": 33}}`。这类意见不依赖任何一版时间线上的位置，片段的 `old` 为 `null`。
- `carry` 为每条留待处理的意见列出其中有素材帧的片段，改写成上面这种源素材意见，ID 为 `<原 ID>#<片段序号>`，可以直接粘进下一次请求的 `notes`。旧版空白上的片段没有素材帧，不会进入 `carry`，仍需人工处理。
- `apply` 从输入重新计算，向新工程的选中轨道附加标记。保留现有标记及其余工程字段。目标目录需已存在且支持硬链接，目标文件需为新路径。输入有误、选择无效、标记键冲突或目标已有文件时，命令返回非零退出码。

## 支持边界

支持两版各选一条启用且未裁剪的 Video 轨道上的硬切，包含 `Clip.1`、`Clip.2` 和 `Gap.1`。使用活动 `ExternalReference.1.target_url` 的完全匹配作为素材身份，接受共享的整数帧率 1–240，帧号使用可由 JSON 精确表示的非负整数，最大为 `2^53−1`。素材重命名、变速、效果、转场、嵌套时间线、禁用项、跨帧率和多轨合成超出支持范围。CLI 读取 OTIO 和 JSON 文本，审阅意见由 JSON 请求提供。

核心将旧意见按镜头边界切分，再按新版本命中区间的端点扫描。素材 URL 索引先定位潜在镜头，再枚举实际覆盖片段的所有新位置，因此长区间无需逐帧扫描。单次分析最多接收每条轨道 20,000 个子项、10,000 条意见，候选查找限额为 1,000,000 次区间检查，报告限额为 100,000 个片段及候选项。

MoonTimeline 0.2.1 的 `otiojson` 负责读取与写回 OTIO 数值和未知字段。MoonReConform 提供跨工程的审阅范围映射、歧义确认和迁移报告。[MoonTimeline](https://github.com/white-bear233/MoonTimeline)

## MoonBit 库

在自己的项目执行 `moon add 123123213weqw/moon_reconform@0.1.0`，导入包 `123123213weqw/moon_reconform`。`Timeline::from_shots` 可接收程序自建的镜头，`plan` 返回逐段候选，`resolve` 应用人工确认。纯 MoonBit 核心可在 JS、Wasm、Wasm GC 和 Native 构建。Node CLI 管理文件 I/O。

## 验证

```sh
moon check --target all --deny-warn
moon test --target js
moon test --target wasm-gc
python scripts/verify.py --live-fixture
```

复核脚本对 40 组确定种子生成的剪辑和 480 条意见逐帧独立验证，并在同一批剪辑上核对 160 条源素材锚点意见和一轮留待处理意见的延续。另用固定提交和 SHA-256 的 ElFuente 60 fps 素材时间线生成一次重剪，1430 帧缩减到 1036 帧，5 条意见中迁移 3 条，保留 2 条。复核覆盖选中目标发现、导出范围、已有标记、OTIO 未知字段保留、请求未知字段拒绝和文件冲突，无需下载视频。[固定版本的 ElFuente OTIO](https://github.com/darbyjohnston/otio-oc-examples/blob/2cc61d92fb4c45dfc0ef8e80f4b5dd7c0005f25f/ElFuente_4096x2160_60fps_10bit_420.otio)

安装 `opentimelineio==0.18.1` 后，使用 `python scripts/verify.py --live-fixture --official-otio` 可让官方 Python OpenTimelineIO 读取导出并核对标记范围。

[一页项目申报书](docs/proposal.md)
