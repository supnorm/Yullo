import Foundation

// One worked example per format and language for Apple's model, given as a prior
// turn: a dictation and how it reads written in that format. The example shows
// the format's layout and register; the model writes the person's own words.
public enum CoreFormatExamples {
    static let examples: [String: [String: CoreVoiceEditExamples.Example]] = [
        "light": [
            "en": .init(
                lead: "",
                text:
                    "um so the client wants the new pricing page by friday and uh they also asked if we can add a faq section i think we can do both but the faq will need copy from marketing",
                result:
                    "So the client wants the new pricing page by Friday, and they also asked if we can add an FAQ section. I think we can do both, but the FAQ will need copy from marketing."
            ),
            "de": .init(
                lead: "",
                text:
                    "also ähm ich wollte nur sagen dass die lieferung erst am dienstag kommt weil der spediteur einen engpass hat wir müssen den kunden informieren",
                result:
                    "Ich wollte nur sagen, dass die Lieferung erst am Dienstag kommt, weil der Spediteur einen Engpass hat. Wir müssen den Kunden informieren."
            ),
            "fr": .init(
                lead: "",
                text:
                    "euh donc la réunion de demain est déplacée à quinze heures et il faut que chacun apporte ses chiffres du trimestre",
                result:
                    "Donc la réunion de demain est déplacée à 15 h, et il faut que chacun apporte ses chiffres du trimestre."
            ),
            "es": .init(
                lead: "",
                text:
                    "bueno eh el proyecto va bien pero necesitamos dos semanas más para las pruebas porque encontramos varios errores en el pago",
                result:
                    "Bueno, el proyecto va bien, pero necesitamos dos semanas más para las pruebas porque encontramos varios errores en el pago."
            ),
            "it": .init(
                lead: "",
                text:
                    "allora ehm il preventivo è pronto ma il cliente vuole uno sconto del dieci per cento prima di firmare",
                result: "Allora, il preventivo è pronto, ma il cliente vuole uno sconto del 10% prima di firmare."),
            "zh": .init(
                lead: "", text: "嗯 那个 我们下周三要交项目报告 大家把自己负责的部分在周一之前发给我 我来汇总",
                result: "我们下周三要交项目报告，大家把自己负责的部分在周一之前发给我，我来汇总。"),
            "zh-Hant": .init(lead: "", text: "嗯 那個 這次的預算超支了大概百分之十五 我們要跟財務部門解釋原因", result: "這次的預算超支了大概15%，我們要跟財務部門解釋原因。")
        ],
        "casual": [
            "en": .init(
                lead: "",
                text:
                    "um so the client wants the new pricing page by friday and uh they also asked if we can add a faq section i think we can do both but the faq will need copy from marketing",
                result:
                    "The client wants the new pricing page by Friday, and they also asked if we can add an FAQ section. I think we can do both, but the FAQ will need copy from marketing."
            ),
            "de": .init(
                lead: "",
                text:
                    "also ähm ich wollte nur sagen dass die lieferung erst am dienstag kommt weil der spediteur einen engpass hat wir müssen den kunden informieren",
                result:
                    "Ich wollte nur sagen, dass die Lieferung erst am Dienstag kommt, weil der Spediteur einen Engpass hat. Wir müssen den Kunden informieren."
            ),
            "fr": .init(
                lead: "",
                text:
                    "euh donc la réunion de demain est déplacée à quinze heures et il faut que chacun apporte ses chiffres du trimestre",
                result:
                    "La réunion de demain est déplacée à 15 h et il faut que chacun apporte ses chiffres du trimestre."),
            "es": .init(
                lead: "",
                text:
                    "bueno eh el proyecto va bien pero necesitamos dos semanas más para las pruebas porque encontramos varios errores en el pago",
                result:
                    "El proyecto va bien, pero necesitamos dos semanas más para las pruebas porque encontramos varios errores en el pago."
            ),
            "it": .init(
                lead: "",
                text:
                    "allora ehm il preventivo è pronto ma il cliente vuole uno sconto del dieci per cento prima di firmare",
                result: "Il preventivo è pronto, ma il cliente vuole uno sconto del 10% prima di firmare."),
            "zh": .init(
                lead: "", text: "嗯 那个 我们下周三要交项目报告 大家把自己负责的部分在周一之前发给我 我来汇总",
                result: "我们下周三要交项目报告，大家把自己负责的部分在周一之前发给我，我来汇总。"),
            "zh-Hant": .init(lead: "", text: "嗯 那個 這次的預算超支了大概百分之十五 我們要跟財務部門解釋原因", result: "這次的預算超支了大概15%，我們要跟財務部門解釋原因。")
        ],
        "polite": [
            "en": .init(
                lead: "",
                text:
                    "um so the client wants the new pricing page by friday and uh they also asked if we can add a faq section i think we can do both but the faq will need copy from marketing",
                result:
                    "The client would like the new pricing page by Friday, and they have also asked whether we could add an FAQ section. I think we can do both, though the FAQ will need copy from marketing."
            ),
            "de": .init(
                lead: "",
                text:
                    "also ähm ich wollte nur sagen dass die lieferung erst am dienstag kommt weil der spediteur einen engpass hat wir müssen den kunden informieren",
                result:
                    "Ich wollte Ihnen nur mitteilen, dass die Lieferung erst am Dienstag kommt, weil der Spediteur einen Engpass hat. Wir müssen den Kunden informieren."
            ),
            "fr": .init(
                lead: "",
                text:
                    "euh donc la réunion de demain est déplacée à quinze heures et il faut que chacun apporte ses chiffres du trimestre",
                result:
                    "La réunion de demain est déplacée à 15 h, et chacun est prié d'apporter ses chiffres du trimestre."
            ),
            "es": .init(
                lead: "",
                text:
                    "bueno eh el proyecto va bien pero necesitamos dos semanas más para las pruebas porque encontramos varios errores en el pago",
                result:
                    "El proyecto va bien, pero necesitamos dos semanas más para las pruebas, ya que encontramos varios errores en el pago."
            ),
            "it": .init(
                lead: "",
                text:
                    "allora ehm il preventivo è pronto ma il cliente vuole uno sconto del dieci per cento prima di firmare",
                result: "Il preventivo è pronto, ma il cliente vorrebbe uno sconto del 10% prima di firmare."),
            "zh": .init(
                lead: "", text: "嗯 那个 我们下周三要交项目报告 大家把自己负责的部分在周一之前发给我 我来汇总",
                result: "我们下周三要交项目报告，请大家把自己负责的部分在周一之前发给我，我来汇总。"),
            "zh-Hant": .init(
                lead: "", text: "嗯 那個 這次的預算超支了大概百分之十五 我們要跟財務部門解釋原因", result: "這次的預算大概超支了15%，我們需要跟財務部門解釋原因。")
        ],
        "email": [
            "en": .init(
                lead: "",
                text:
                    "um so the client wants the new pricing page by friday and uh they also asked if we can add a faq section i think we can do both but the faq will need copy from marketing",
                result:
                    "So the client wants the new pricing page by Friday. They also asked if we can add an FAQ section.\n\nI think we can do both, but the FAQ will need copy from marketing."
            ),
            "de": .init(
                lead: "",
                text:
                    "also ähm ich wollte nur sagen dass die lieferung erst am dienstag kommt weil der spediteur einen engpass hat wir müssen den kunden informieren",
                result:
                    "Ich wollte nur sagen, dass die Lieferung erst am Dienstag kommt, weil der Spediteur einen Engpass hat.\n\nWir müssen den Kunden informieren."
            ),
            "fr": .init(
                lead: "",
                text:
                    "euh donc la réunion de demain est déplacée à quinze heures et il faut que chacun apporte ses chiffres du trimestre",
                result:
                    "La réunion de demain est déplacée à 15 h.\n\nIl faut que chacun apporte ses chiffres du trimestre."
            ),
            "es": .init(
                lead: "",
                text:
                    "bueno eh el proyecto va bien pero necesitamos dos semanas más para las pruebas porque encontramos varios errores en el pago",
                result:
                    "El proyecto va bien, pero necesitamos dos semanas más para las pruebas.\n\nEncontramos varios errores en el pago."
            ),
            "it": .init(
                lead: "",
                text:
                    "allora ehm il preventivo è pronto ma il cliente vuole uno sconto del dieci per cento prima di firmare",
                result: "Il preventivo è pronto.\n\nIl cliente vuole uno sconto del 10% prima di firmare."),
            "zh": .init(
                lead: "", text: "嗯 那个 我们下周三要交项目报告 大家把自己负责的部分在周一之前发给我 我来汇总",
                result: "我们下周三要交项目报告。\n\n请大家把自己负责的部分在周一之前发给我，我来汇总。"),
            "zh-Hant": .init(
                lead: "", text: "嗯 那個 這次的預算超支了大概百分之十五 我們要跟財務部門解釋原因", result: "這次的預算超支了大概15%。\n\n我們要跟財務部門解釋原因。")
        ],
        "formal": [
            "en": .init(
                lead: "",
                text:
                    "um so the client wants the new pricing page by friday and uh they also asked if we can add a faq section i think we can do both but the faq will need copy from marketing",
                result:
                    "The client requires the new pricing page by Friday and has also asked whether we can add an FAQ section. I believe we can do both; however, the FAQ will require copy from marketing."
            ),
            "de": .init(
                lead: "",
                text:
                    "also ähm ich wollte nur sagen dass die lieferung erst am dienstag kommt weil der spediteur einen engpass hat wir müssen den kunden informieren",
                result:
                    "Ich möchte mitteilen, dass die Lieferung erst am Dienstag eintrifft, da der Spediteur einen Engpass hat. Der Kunde muss informiert werden."
            ),
            "fr": .init(
                lead: "",
                text:
                    "euh donc la réunion de demain est déplacée à quinze heures et il faut que chacun apporte ses chiffres du trimestre",
                result:
                    "La réunion de demain est déplacée à 15 h. Il est demandé à chacun d'apporter ses chiffres du trimestre."
            ),
            "es": .init(
                lead: "",
                text:
                    "bueno eh el proyecto va bien pero necesitamos dos semanas más para las pruebas porque encontramos varios errores en el pago",
                result:
                    "El proyecto avanza satisfactoriamente; no obstante, necesitamos dos semanas adicionales para las pruebas, ya que hemos encontrado varios errores en el pago."
            ),
            "it": .init(
                lead: "",
                text:
                    "allora ehm il preventivo è pronto ma il cliente vuole uno sconto del dieci per cento prima di firmare",
                result: "Il preventivo è pronto; tuttavia, il cliente richiede uno sconto del 10% prima di firmare."),
            "zh": .init(
                lead: "", text: "嗯 那个 我们下周三要交项目报告 大家把自己负责的部分在周一之前发给我 我来汇总",
                result: "我们下周三需提交项目报告，请各位将自己负责的部分在周一之前发送给我，由我负责汇总。"),
            "zh-Hant": .init(lead: "", text: "嗯 那個 這次的預算超支了大概百分之十五 我們要跟財務部門解釋原因", result: "本次預算大概超支了15%，我們須向財務部門說明原因。")
        ],
        "professional": [
            "en": .init(
                lead: "",
                text:
                    "um so the client wants the new pricing page by friday and uh they also asked if we can add a faq section i think we can do both but the faq will need copy from marketing",
                result:
                    "The client wants the new pricing page by Friday and has also asked whether we can add an FAQ section. I think we can do both, but the FAQ will need copy from marketing."
            ),
            "de": .init(
                lead: "",
                text:
                    "also ähm ich wollte nur sagen dass die lieferung erst am dienstag kommt weil der spediteur einen engpass hat wir müssen den kunden informieren",
                result:
                    "Ich wollte Ihnen mitteilen, dass die Lieferung erst am Dienstag kommt, weil der Spediteur einen Engpass hat. Wir müssen den Kunden informieren."
            ),
            "fr": .init(
                lead: "",
                text:
                    "euh donc la réunion de demain est déplacée à quinze heures et il faut que chacun apporte ses chiffres du trimestre",
                result: "La réunion de demain est déplacée à 15 h. Merci à chacun d'apporter ses chiffres du trimestre."
            ),
            "es": .init(
                lead: "",
                text:
                    "bueno eh el proyecto va bien pero necesitamos dos semanas más para las pruebas porque encontramos varios errores en el pago",
                result:
                    "El proyecto va bien, pero necesitamos dos semanas más para las pruebas porque encontramos varios errores en el pago."
            ),
            "it": .init(
                lead: "",
                text:
                    "allora ehm il preventivo è pronto ma il cliente vuole uno sconto del dieci per cento prima di firmare",
                result: "Il preventivo è pronto, ma il cliente vuole uno sconto del 10% prima di firmare."),
            "zh": .init(
                lead: "", text: "嗯 那个 我们下周三要交项目报告 大家把自己负责的部分在周一之前发给我 我来汇总",
                result: "我们下周三要交项目报告，麻烦大家把自己负责的部分在周一之前发给我，我来汇总。"),
            "zh-Hant": .init(
                lead: "", text: "嗯 那個 這次的預算超支了大概百分之十五 我們要跟財務部門解釋原因", result: "這次的預算大概超支了15%，我們需要跟財務部門解釋原因。")
        ],
        "bullets": [
            "en": .init(
                lead: "",
                text:
                    "um so the client wants the new pricing page by friday and uh they also asked if we can add a faq section i think we can do both but the faq will need copy from marketing",
                result:
                    "- The client wants the new pricing page by Friday.\n- The client also asked if we can add an FAQ section.\n- I think we can do both, but the FAQ will need copy from marketing."
            ),
            "de": .init(
                lead: "",
                text:
                    "also ähm ich wollte nur sagen dass die lieferung erst am dienstag kommt weil der spediteur einen engpass hat wir müssen den kunden informieren",
                result:
                    "- Die Lieferung kommt erst am Dienstag.\n- Der Spediteur hat einen Engpass.\n- Wir müssen den Kunden informieren."
            ),
            "fr": .init(
                lead: "",
                text:
                    "euh donc la réunion de demain est déplacée à quinze heures et il faut que chacun apporte ses chiffres du trimestre",
                result:
                    "- La réunion de demain est déplacée à 15 h.\n- Il faut que chacun apporte ses chiffres du trimestre."
            ),
            "es": .init(
                lead: "",
                text:
                    "bueno eh el proyecto va bien pero necesitamos dos semanas más para las pruebas porque encontramos varios errores en el pago",
                result:
                    "- El proyecto va bien.\n- Necesitamos dos semanas más para las pruebas.\n- Encontramos varios errores en el pago."
            ),
            "it": .init(
                lead: "",
                text:
                    "allora ehm il preventivo è pronto ma il cliente vuole uno sconto del dieci per cento prima di firmare",
                result: "- Il preventivo è pronto.\n- Il cliente vuole uno sconto del 10% prima di firmare."),
            "zh": .init(
                lead: "", text: "嗯 那个 我们下周三要交项目报告 大家把自己负责的部分在周一之前发给我 我来汇总",
                result: "- 我们下周三要交项目报告。\n- 大家把自己负责的部分在周一之前发给我。\n- 我来汇总。"),
            "zh-Hant": .init(
                lead: "", text: "嗯 那個 這次的預算超支了大概百分之十五 我們要跟財務部門解釋原因", result: "- 這次的預算大概超支了15%。\n- 我們要跟財務部門解釋原因。")
        ]
    ]

    // The example led the way the request will be: the same lead line before its text.
    public static func example(style: RewriteStyle, languageID: String?, lead: String) -> CoreVoiceEditExamples.Example?
    {
        guard let key = CoreLanguageConventions.key(languageID), let found = examples[style.rawValue]?[key] else {
            return nil
        }
        return .init(lead: lead, text: found.text, result: found.result)
    }
}
