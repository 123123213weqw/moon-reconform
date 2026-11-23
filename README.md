# MoonReConform

MoonReConform 将旧版剪辑上的审阅意见迁移到重剪后的 OpenTimelineIO 工程，画面轨道和声音轨道都可以。剪辑师可以追踪一段意见对应的素材帧，确认重复镜头的目标，或者把缺失素材和旧版空白上的意见留待人工处理。意见按素材而不是时间码认亲，所以能一轮一轮审下去：没处理完的自动带到下一版，已经写进工程的标记也能读回来接着用。

## 安装与运行

命令行使用 MoonBit `0.10.20+65efd5b93` 和 Node.js 22 或更新版本。复核脚本另需 Python 3.10 或更新版本。在仓库根目录运行以下命令。

```sh
moon update
python scripts/verify.py --demo _build/example
moon run cmd/main --target js -- plan _build/example/before.otio _build/example/after.otio _build/example/request.json
moon run cmd/main --target js -- apply _build/example/before.otio _build/example/after.otio _build/example/request.json _build/example/reviewed.otio
```

两条命令都在标准输出返回 JSON。失败时是 `{"ok": false, "error": "..."}` 并以非零状态退出，`error` 只写路径、用法或被违反的规则。`moon run cmd/main --target js -- --help` 打印用法。成功时其中 `notes[].pieces` 记录旧片段、源素材和所有新候选，`held` 记录待处理意见的 ID，`transfers` 记录可写入的片段，`carry` 把留待处理的意见改写成下一次请求可以直接使用的源素材意见。示例请求包含两项已确认的候选，最终写入五段标记，保留两条待处理意见。重新运行示例时给生成目录和目标 OTIO 选择新路径。更新内容见[更新日志](CHANGELOG.md)，依赖许可见[第三方依赖](THIRD_PARTY.md)。

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

- `old_track` 和 `new_track` 是各工程 `tracks.children` 中从零开始的索引，所选轨道可以是 Video 或 Audio。时间以所选轨道第一帧为 0，各端点为帧号。区间为 `[start, stop)`，省略 `stop` 表示单帧。
- 请求、单条意见和人工确认里的未知字段按名拒绝。例如把 `stop` 写成 `end` 会返回 `annotation n1: unknown field end`，不会把区间意见悄悄当作单帧意见。OTIO 工程自身的未知字段不受影响，原样保留。
- 从 `plan` 的报告确认 `ambiguous` 片段的候选，将选中的 `clip` 和该片段在 `pieces` 中的索引加入 `selections`，再用同一对 OTIO 文件执行 `apply`。新轨道中空白也占用子项索引。
- `unique` 表示恰有一个新位置，`ambiguous` 表示两个以上，`deleted` 表示没有新位置，`gap` 表示旧位置处于轨道空白。只有一条意见的全部片段解析完毕才会生成标记。有些意见会拆成数个标记，原 ID 和片段序号保存在 `metadata.moon_reconform`。
- 意见也可以锚定在源素材上：给出 `media`（素材 URL）和 `source`（素材帧区间），不给出 `start` 与 `stop`，例如 `{"id": "c1", "text": "核对片头", "media": "file:///shoot/A.mov", "source": {"start": 30, "stop": 33}}`。这类意见不依赖任何一版时间线上的位置，片段的 `old` 为 `null`。
- `carry` 为每条留待处理的意见列出其中有素材帧的片段，改写成上面这种源素材意见，ID 为 `<原 ID>#<片段序号>`，可以直接粘进下一次请求的 `notes`。旧版空白上的片段没有素材帧，不会进入 `carry`，仍需人工处理。
- `apply` 从输入重新计算，向新工程的选中轨道附加标记。保留现有标记及其余工程字段；没有任何意见迁移成功时不写入标记。目标目录需已存在且支持硬链接，目标文件需为新路径。输入有误、选择无效、标记键冲突或目标已有文件时，命令返回非零退出码。

## 反复审片

每一轮把上一轮 `apply` 的输出当作 `old.otio`。

1. 把上一轮报告的 `carry` 粘进这一轮请求的 `notes`。留待处理的意见在新时间线上没有位置，能带走的是它指向的素材。
2. 需要延续上一轮已写入的标记时，在请求里加上 `"from_markers": true`。旧工程选中轨道上带 `metadata.moon_reconform` 的标记按轨道顺序读回成意见，ID 为 `<原 ID>#<片段序号>`，排在手写意见之后，不必重新输入。读回的意见同样出现在 `carry` 里，没有处理完就继续带到下一轮。
3. `apply` 写入新工程时，读回的意见一旦迁移成功，剪辑软件按时间码带进新工程的那份旧副本会先被移除，再追加落在素材上的新标记。留待处理的读回意见不改动任何现有标记，旧副本留在剪辑师放置的位置。

`apply` 写出的每个标记在 `metadata.moon_reconform` 中记录 `note_id`、`piece`、`target_child`，以及它落在哪段素材上（`media` 和 `source`）。`from_markers` 读的是这份素材记录，不是标记此刻画在哪个时间码。剪辑软件按时间码搬动标记后，意见仍然贴在原素材上。报告的 `notes[]` 和 `transfers[]` 用 `origin` 指明一条意见读自哪个标记。ID 逐轮接续：`entire-old#0#0` 是意见 `entire-old#0` 的第 0 个片段。

读回时按名拒绝的情况：同一标记在旧轨道上出现两次（报出两处位置），`piece` 为负，素材记录缺失或区间为空，标记的 schema 不是 `Marker.1` 或 `Marker.2`。没有这段 metadata 的标记属于剪辑师，读回时跳过。标记的 metadata 能否随工程在剪辑软件中往返取决于所用软件；被丢弃的标记读回时等同剪辑师的标记，这时用 `carry` 和保存的请求 JSON 延续意见。0.2.0 之前导出的标记没有素材记录，读回时提示 `records no footage`，用本版本对当时的两个工程重新执行一次 `apply` 即可。读回的意见计入 10,000 条意见的上限，与手写意见 ID 重复时整份请求被拒绝。

## 支持边界

支持两版各选一条启用且未裁剪的 Video 或 Audio 轨道上的硬切，包含 `Clip.1`、`Clip.2` 和 `Gap.1`。轨道种类不参与匹配：素材身份是活动 `ExternalReference.1.target_url` 的完全匹配加帧区间，所以同一段素材既可以在画面轨上，也可以在声音轨上。所选轨道的 `markers` 里每一项都必须是对象，标记内部只有 `metadata.moon_reconform` 会被解读。接受共享的整数帧率 1–240，帧号使用可由 JSON 精确表示的非负整数，最大为 `2^53−1`。素材重命名、变速、效果、转场、嵌套时间线、禁用项、跨帧率和多轨合成超出支持范围。CLI 读取 OTIO 和 JSON 文本，审阅意见由 JSON 请求提供。

核心将旧意见按镜头边界切分，再按新版本命中区间的端点扫描。素材 URL 索引先定位潜在镜头，再枚举实际覆盖片段的所有新位置，因此长区间无需逐帧扫描。单次分析最多接收每条轨道 20,000 个子项、10,000 条意见（含读回的标记）和 100,000 个人工确认。候选查找限额为 1,000,000 次区间检查，报告限额为 100,000 个片段及候选项，两个预算按单次分析计算。输入文件上限为 16,000,000 字节，所以这些限额相互制约：20,000 个子项加 10,000 条意见的最大请求里，最大的文件约 14.85 MB。

MoonTimeline 0.2.1 的 `otiojson` 负责读取与写回 OTIO 数值和未知字段。MoonReConform 提供跨工程的审阅范围映射、歧义确认和迁移报告。[MoonTimeline](https://github.com/white-bear233/MoonTimeline)

## MoonBit 库

在自己的项目执行 `moon add 123123213weqw/moon_reconform@0.3.0`，导入包 `123123213weqw/moon_reconform`。`read_otio` 和 `read_request` 读取两版时间线与请求，`plan` 返回逐段候选，`resolve` 应用人工确认，`carried` 给出下一轮的源素材意见，`read_notes_from_markers` 读回导出的标记，`with_markers` 返回附加了标记的新工程，`report_json` 输出与命令行相同的报告。`Timeline::from_shots` 可接收程序自建的镜头。核心包不导入任何第三方包，只依赖 `moonbitlang/core`，可在 JS、Wasm、Wasm GC 和 Native 构建。Node CLI 管理文件 I/O，并用 MoonTimeline 的 `otiojson` 无损读写 OTIO 文本。

## 验证

```sh
moon check --target all --deny-warn
moon test --target js
moon test --target wasm-gc
python scripts/verify.py --live-fixture
python scripts/fuzz.py --count 600
python scripts/mutate.py
```

单元测试共 12 个，在 JS、Wasm、Wasm GC 和 Native 四个目标上运行。CI 对四个目标各检查一遍，在 JS 上依次运行复核脚本、模糊测试和针对发布构建的复核，另一个作业运行故障注入。

**复核脚本**（`scripts/verify.py`）独立于工具算出每条意见的每个片段应当是什么，用的是两种互不相同的算法。区间规划把每段素材与所有新位置做区间相交，在覆盖集合变化的地方切分，只用 Python 整数，任何量级都能算；逐帧枚举在剪辑足够短时把每一帧都查一遍。两者的结果都必须与报告逐项相等，`held`、`transfers` 和 `carry` 再由片段推出。脚本依次走过九段场景：

- 示例工程：5 条意见，2 条留待处理；含对未知字段、变速、非整数帧和无效选择的拒绝。
- 40 组确定种子生成的剪辑和 480 条意见，同一批剪辑上的 160 条源素材锚点意见，以及留待处理意见的延续。
- 三轮审片：第一轮写出的 5 个标记被按时间码搬进第三版剪辑后全部离开原素材，读回后 2 条落回素材，3 条随 `carry` 进入第三轮，最终 18 条意见全部落在手算的位置上。
- 超出可枚举范围：素材起点在 `2^52` 量级、长 `2^51` 帧的剪辑、正好 `2^53−1` 帧的剪辑与自身比对，最后一个可表示的帧落在自己身上。`plan` 用时约 0.1 秒。
- 命令自身的失败：18 组，逐条核对完整消息，包括正好 16,000,000 字节的输入可读而多一字节不可读。
- 音频轨道：画面与声音并排的两轨工程，意见落在声音轨上，第二轮读回时两份旧副本被取代、一份保留。
- 预算与计数：候选查找预算在 999 条意见处接受、1000 条处拒绝，报告预算在 49 条处接受、50 条处拒绝；子项和意见在临界处被接受、越一步被拒绝；人工确认的上限受报告预算制约，只测越界拒绝；帧率 1 和 240 被接受，0 和 241 被拒绝；超出 Int32 或超出轨道栈的索引被拒绝。
- 临界请求：20,000 个子项对 20,000 个子项、10,000 条意见，约 5 秒答完，每个落点经区间规划、逐帧枚举和闭式公式三方核对。
- ElFuente：用固定提交和 SHA-256 的 60 fps 素材时间线生成一次重剪，1430 帧缩减到 1036 帧，5 条意见中迁移 3 条，保留 2 条。[固定版本的 ElFuente OTIO](https://github.com/darbyjohnston/otio-oc-examples/blob/2cc61d92fb4c45dfc0ef8e80f4b5dd7c0005f25f/ElFuente_4096x2160_60fps_10bit_420.otio)

**模糊测试**（`scripts/fuzz.py`）对示例的三个文档做一到三次变异，包括改帧号和索引（直到帧号能表示的边缘）、改 schema、轨道种类、素材 URL 和名称、删除、重复、移动或混入子项、标记、意见和确认、增删字段，以及按剪辑师的方式修改一个片段：裁剪、滑动、拆分、与邻段交换、变成黑场或延长。每个变异都必须得到一个状态，退出码为 0 或 1，标准输出是一个 JSON 对象，标准错误为空。变异后的文档如果仍然是一对真实的剪辑，答案必须通过复核，导出也要核对；剪辑太长时只做区间规划。另有 33 份根本不是文档的输入，分别当作旧工程和请求送入，包括空文件、单独的字节序标记、非法 UTF-8、`NaN`、20 万层嵌套、500 万字节的键。一次两万次的战役里，11,469 个变异被接受并逐个验证，181 个因数值过大只用区间规划验证，8,350 个被拒绝且各带理由，没有崩溃，也没有与复核不一致的。CI 每次运行 600 次。 失败的变异会把文档留在 `_build/fuzz` 下，按 seed 可以复现。

**故障注入**（`scripts/mutate.py`）保存 33 个已知故障，每个对应工具承诺的一条规则：片段冒称旧轨道上的范围、扫描晚一帧收尾、候选顺序、预算、限额、32 位截断、旧副本不被取代、标记按时间码读回、命令行的各项规则等。每个故障在仓库的私有副本里注入、构建，单元测试或复核脚本至少有一个必须失败。目前 18 个两者都能抓到，13 个只有复核脚本能抓到，2 个只有单元测试能抓到，没有漏网的。

计时数字来自调试构建。

安装 `opentimelineio==0.18.1` 后，使用 `python scripts/verify.py --live-fixture --official-otio` 可让官方 Python OpenTimelineIO 读取导出并核对标记范围。

[一页项目申报书](docs/proposal.md)
