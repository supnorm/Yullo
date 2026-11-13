import Foundation

// One worked example for Apple's model, in the text's own language, given as a
// prior turn: feedback ("too long", "confusing", "rude") read as the edit it
// implies. Only for those three meanings, and only in these languages: an
// example in another language would lead the model to translate the text.
public enum CoreVoiceEditExamples {
    public struct Example: Equatable, Sendable {
        public let lead: String
        public let text: String
        public let result: String
        public init(lead: String, text: String, result: String) {
            self.lead = lead
            self.text = text
            self.result = result
        }
    }
    static let examples: [String: [String: Example]] = [
        "shorter": [
            "en": Example(
                lead: "Make it noticeably shorter; keep the key facts.",
                text:
                    "Just a quick reminder that the invoice we talked about last week is still open, so please pay it when you get a chance before the end of the month.",
                result: "Reminder: last week's invoice is still open. Please pay it by the end of the month."),
            "zh": Example(
                lead: "Make it noticeably shorter; keep the key facts.",
                text: "我想跟大家说一下，就是我们原本定在周三的那个培训，因为讲师那边临时有事，所以要改到周五上午十点了。",
                result: "原定周三的培训因讲师有事，改到周五上午十点。"),
            "de": Example(
                lead: "Make it noticeably shorter; keep the key facts.",
                text:
                    "Ich wollte nur kurz Bescheid geben, dass ich die Unterlagen, über die wir gestern gesprochen haben, leider erst morgen Vormittag schicken kann.",
                result: "Die besprochenen Unterlagen schicke ich erst morgen Vormittag."),
            "fr": Example(
                lead: "Make it noticeably shorter; keep the key facts.",
                text:
                    "Je voulais simplement vous prévenir que la réunion que nous avions prévue jeudi est reportée à lundi prochain à cause d'un imprévu.",
                result: "La réunion de jeudi est reportée à lundi prochain."),
            "es": Example(
                lead: "Make it noticeably shorter; keep the key facts.",
                text:
                    "Solo quería avisarte de que el pedido que hicimos la semana pasada todavía no ha llegado y no sabemos cuándo va a llegar.",
                result: "El pedido de la semana pasada aún no ha llegado y no sabemos cuándo llegará."),
            "ja": Example(
                lead: "Make it noticeably shorter; keep the key facts.",
                text: "念のためお伝えしておきたいのですが、来週の打ち合わせは会議室の都合で月曜日から火曜日の午後二時に変更になりました。",
                result: "来週の打ち合わせは火曜日の午後二時に変更になりました。")
        ],
        "clearer": [
            "en": Example(
                lead: "Rewrite it so it is clearer and simpler, in plain words.",
                text:
                    "Pursuant to the revised schedule, deliverables are contingent upon stakeholder sign-off prior to Friday.",
                result: "Under the new schedule, we can deliver once the stakeholders approve before Friday."),
            "zh": Example(
                lead: "Rewrite it so it is clearer and simpler, in plain words.",
                text: "鉴于相关方案尚需进一步论证，故上线时间暂定为待定状态。",
                result: "方案还要再讨论，所以上线时间还没定。"),
            "de": Example(
                lead: "Rewrite it so it is clearer and simpler, in plain words.",
                text: "Die Auslieferung erfolgt nach Maßgabe der Freigabe durch die zuständigen Stellen.",
                result: "Wir liefern, sobald die zuständigen Stellen zustimmen."),
            "fr": Example(
                lead: "Rewrite it so it is clearer and simpler, in plain words.",
                text: "La livraison s'effectuera sous réserve de la validation préalable des instances concernées.",
                result: "Nous livrerons dès que les responsables auront validé."),
            "es": Example(
                lead: "Rewrite it so it is clearer and simpler, in plain words.",
                text: "La entrega se realizará conforme a la aprobación previa de las instancias correspondientes.",
                result: "Entregaremos cuando los responsables lo aprueben."),
            "ja": Example(
                lead: "Rewrite it so it is clearer and simpler, in plain words.",
                text: "関係各所の承認を前提として、納品日程を確定させる運びとなります。",
                result: "関係者が承認したら、納品日を決めます。")
        ],
        "softer": [
            "en": Example(
                lead: "Make it softer and more polite; keep every request.",
                text: "Fix the login page today. It's been broken for days.",
                result: "Could you please fix the login page today? It has been broken for a few days."),
            "zh": Example(
                lead: "Make it softer and more polite; keep every request.",
                text: "今天必须把登录页修好，已经坏了好几天了。",
                result: "麻烦您今天把登录页修好，好吗？它已经坏了好几天了。"),
            "de": Example(
                lead: "Make it softer and more polite; keep every request.",
                text: "Reparieren Sie heute die Login-Seite. Die ist seit Tagen kaputt.",
                result:
                    "Könnten Sie bitte heute die Login-Seite reparieren? Sie funktioniert seit ein paar Tagen nicht."),
            "fr": Example(
                lead: "Make it softer and more polite; keep every request.",
                text: "Réparez la page de connexion aujourd'hui. Elle est cassée depuis des jours.",
                result:
                    "Pourriez-vous réparer la page de connexion aujourd'hui ? Elle ne fonctionne plus depuis quelques jours."
            ),
            "es": Example(
                lead: "Make it softer and more polite; keep every request.",
                text: "Arregla hoy la página de inicio de sesión. Lleva días rota.",
                result: "¿Podría arreglar hoy la página de inicio de sesión, por favor? Lleva unos días sin funcionar."),
            "ja": Example(
                lead: "Make it softer and more polite; keep every request.",
                text: "今日中にログイン画面を直して。何日も壊れてる。",
                result: "今日中にログイン画面を直していただけますか。数日前から動いていないようです。")
        ]
    ]

    public static func example(for instruction: String, languageID: String?) -> Example? {
        guard case .meaning(let meaning) = CoreVoiceEditPrompt.intent(of: instruction),
            let key = CoreLanguageConventions.key(languageID)
        else { return nil }
        let kind =
            meaning.contains("shorter")
            ? "shorter" : meaning.contains("clearer") ? "clearer" : meaning.contains("softer") ? "softer" : nil
        return kind.flatMap { examples[$0]?[key] }
    }
}
