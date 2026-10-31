import Foundation

/// 台本骨架模板。纯本地静态数据，不联网、不生成内容，只给不会写稿的人一个起点。
struct ScriptTemplate: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let scene: String
    let summary: String
    let accentHex: UInt32
    let body: String

    /// 卡片顶部配图，按模板 id 映射到资源目录里的 imageset。
    var imageName: String {
        switch id {
        case "hook": "TemplateHook"
        case "product": "TemplateProduct"
        case "knowledge": "TemplateKnowledge"
        case "store": "TemplateStore"
        case "live": "TemplateLive"
        case "story": "TemplateEmotion"
        default: "TemplateHook"
        }
    }
}

enum TemplateCatalog {

    static let scenes: [String] = ["全部", "开场钩子", "产品讲解", "知识科普", "探店实录", "直播话术", "情感共鸣"]

    static let all: [ScriptTemplate] = [
        ScriptTemplate(
            id: "hook",
            title: "三秒钩子开场",
            scene: "开场钩子",
            summary: "前 3 秒抓人，把结论提到最前面",
            accentHex: 0x4B6EF5,
            body: """
            [直接给结论，不要铺垫]

            很多人做[你的领域]一直卡在[具体痛点]，其实问题不在努力，在方法。

            我先说结论：[一句话结论]。

            接下来三十秒，我用三件事说明为什么。

            第一，[原因或事实]。
            第二，[反常识的点]。
            第三，[可以直接用的做法]。

            如果你也在[同样的处境]，把这条存下来，下次直接用。
            """
        ),
        ScriptTemplate(
            id: "product",
            title: "产品讲解四步",
            scene: "产品讲解",
            summary: "痛点、方案、证据、行动，一段落一步",
            accentHex: 0x2F9E64,
            body: """
            先说一个大家都遇到过的场景。

            [描述用户的具体困境，越具体越好]。

            我们做[产品名]就是为了解决这件事。

            它做了三件事：
            一是[能力一]，解决[对应痛点]。
            二是[能力二]，解决[对应痛点]。
            三是[能力三]，这是别人没做的。

            实际效果是这样的：[给出可验证的数据或对比]。

            [价格或获取方式]。需要的可以看下面。
            """
        ),
        ScriptTemplate(
            id: "knowledge",
            title: "知识科普三段式",
            scene: "知识科普",
            summary: "是什么、为什么、怎么办",
            accentHex: 0xD85A30,
            body: """
            今天讲清楚一个问题：[问题]。

            先说它是什么。
            [定义，用一句大白话]。

            再说为什么会这样。
            [机制或原理，最多讲两层，不要展开第三层]。

            最后说怎么办。
            第一步，[动作]。
            第二步，[动作]。
            第三步，[动作]。

            记住一句话就够了：[核心结论]。

            下一期讲[下一个相关话题]，想看的说一声。
            """
        ),
        ScriptTemplate(
            id: "store",
            title: "探店实录",
            scene: "探店实录",
            summary: "环境、招牌、口感、性价比，四点收口",
            accentHex: 0xBA7517,
            body: """
            今天来[店名]，在[位置]。

            先说环境。[一两句，画面感优先]。

            招牌是[菜名]，我点了一份。

            [第一口的真实感受，说具体口感，不要只说好吃]。

            价格[具体金额]，[分量或性价比判断]。

            值得来的理由：[一句话]。
            不适合的情况：[一句话，反而更可信]。

            地址放在评论区，人多的时段记得避开[时段]。
            """
        ),
        ScriptTemplate(
            id: "live",
            title: "直播开场话术",
            scene: "直播话术",
            summary: "留人、预告、福利、逼单四个环节",
            accentHex: 0xD4537E,
            body: """
            刚进来的朋友先别划走，今天这场只有[时长]。

            三件事先说清楚。

            第一，今天讲什么：[主题]，讲完你会知道[收益]。

            第二，今天的福利：[具体福利]，只在直播间，[获取条件]。

            第三，节奏：[时间点] 讲[内容一]，[时间点] 讲[内容二]。

            现在在的朋友打个「1」，我看到人数够了就开讲。

            [互动引导]。

            [进入正题第一段]。
            """
        ),
        ScriptTemplate(
            id: "story",
            title: "情感共鸣叙述",
            scene: "情感共鸣",
            summary: "一个具体场景起手，落到一句可记住的话",
            accentHex: 0x7F77DD,
            body: """
            [具体的时间、地点、人物，越具体越真]。

            那天[发生了什么]。

            我当时的第一反应是[真实反应，可以是不体面的]。

            后来我想明白一件事：[转折]。

            其实很多人都有过类似的时刻，只是没说出口。

            [落到一句可以被记住、被转发的话]。

            如果你也经历过，评论区留一句，我一条一条看。
            """
        )
    ]

    static func templates(in scene: String) -> [ScriptTemplate] {
        scene == "全部" ? all : all.filter { $0.scene == scene }
    }
}
