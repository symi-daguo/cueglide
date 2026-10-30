# 参与贡献

感谢你愿意花时间改进 CueGlide。

## 提交之前

1. 先搜索现有 Issue，避免重复。
2. 较大的改动（新增功能、重构核心算法）请先开 Issue 说明动机和方案，达成一致后再动手，避免白写。
3. 小的修复（拼写、样式、明显的 bug）可以直接提 PR。

## 开发环境

```bash
brew install xcodegen
git clone https://github.com/symi-daguo/cueglide.git
cd cueglide
xcodegen generate
open CueGlide.xcodeproj
```

要求 Xcode 27.0 及以上，Swift 6。

改动 `project.yml` 后需要重新执行 `xcodegen generate`，不要直接手改 `project.pbxproj`。

## 代码约定

- 遵循 Swift 6 语言模式与完整并发检查。不要用 `@unchecked Sendable` 绕过并发检查；确实需要跨队列共享状态时（如相机采集），用锁保护并在类型注释里写清理由。
- UI 层状态用 `@Observable`，不要引入 Combine。
- 提词滚动的坐标统一用词索引，不要在业务层直接操作像素偏移。
- 新增的可见文案一律用中文，注释也用中文。
- 不引入第三方依赖，保持零依赖。
- 不引入埋点、广告、统计 SDK。

## 提交信息

格式：

```
类型: 简要说明
```

类型取值：`feat`、`fix`、`refactor`、`docs`、`style`、`perf`、`test`、`chore`。

示例：

```
feat: 提词页支持双向镜像
fix: 修复换字号后阅读进度丢失
docs: 补充滚动速度的计算说明
```

## PR 要求

1. 一个 PR 只做一件事，改动范围要聚焦。
2. 说明改了什么、为什么改、怎么验证的。
3. UI 相关改动请附截图，注明机型和系统版本。
4. 涉及真机能力（相机、麦克风、蓝牙、外接屏）的改动，请说明是否已在真机验证。模拟器不提供这些硬件行为。
5. 保持构建通过，不引入新的编译警告。

## 行为准则

对事不对人。技术讨论可以尖锐，但不接受人身攻击、歧视性言论和骚扰。
