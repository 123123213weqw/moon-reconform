# 第三方依赖

MoonReConform 自身以 Apache-2.0 许可发布，全文见仓库根目录的 [LICENSE](LICENSE)。下表列出 `moon update` 为本模块解析的第三方组件。

| 组件 | 版本 | 许可证 | 用途 | 上游 |
| --- | --- | --- | --- | --- |
| `white-bear233/moontimeline`，使用其中的 `otiojson` 包 | 0.2.1 | Apache-2.0 | 命令行读写 OTIO JSON，精确保留数值与未知字段 | [MoonTimeline](https://github.com/white-bear233/MoonTimeline) |
| `moonbit-community/flate` | 0.9.0 | Apache-2.0 | 上一项声明的模块级依赖；本项目用到的 `otiojson` 包不导入它 | [flate](https://github.com/moonbit-community/flate) |

纯 MoonBit 核心包不导入任何第三方包，只依赖 MoonBit 标准库 `moonbitlang/core`。

验证脚本在使用 `--official-otio` 时需要 Python 的 OpenTimelineIO 0.18.1（Apache-2.0，[OpenTimelineIO](https://github.com/AcademySoftwareFoundation/OpenTimelineIO)）。它只用于核对导出结果，不随包分发。

第三方组件的名称与许可证归其各自作者所有。
