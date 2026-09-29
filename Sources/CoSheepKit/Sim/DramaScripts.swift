import Foundation

// Ex-drama-scripts.ts.

nonisolated enum DramaScriptKind: String, CaseIterable, Codable {
    case feudStart = "feud_start"
    case feudSnipe = "feud_snipe"
    case jealousy
    case mediation
    case reconciliation
    case inseparable
}

private func scriptLine(_ speakerId: String, _ text: String, _ duration: Double, _ delay: Double,
                  _ animation: SheepAnimation? = nil) -> ConversationLine {
    ConversationLine(speakerId: speakerId, text: text, duration: duration, delay: delay, animation: animation)
}

// $A/$B are the pair; $M is the mediator (mediation scripts only).
private let SCRIPTS: [DramaScriptKind: [ConversationScript]] = [
    .feudStart: [
        [
            scriptLine("$A", "You know what? No. I'm done.", 3500, 0, .headshake),
            scriptLine("$B", "DONE? *I'M* done!", 3000, 600, .vibrate),
            scriptLine("$A", "Fine!", 2000, 500),
            scriptLine("$B", "FINE!", 2000, 400),
        ],
        [
            scriptLine("$A", "I saw what you did at the campfire.", 3500, 0),
            scriptLine("$B", "Oh, we're doing THIS now?", 3000, 700, .headshake),
            scriptLine("$A", "We are ABSOLUTELY doing this now.", 3500, 600, .vibrate),
        ],
    ],
    .feudSnipe: [
        [
            scriptLine("$A", "*pointedly grazes elsewhere*", 3000, 0),
            scriptLine("$B", "The grass is better over here anyway.", 3500, 700, .headshake),
        ],
        [
            scriptLine("$A", "Some sheep have no shame.", 3000, 0),
            scriptLine("$B", "Some sheep should mind their own wool.", 3500, 700),
        ],
        [
            scriptLine("$A", "Hmph.", 2000, 0, .headshake),
            scriptLine("$B", "Hmph indeed.", 2000, 500, .headshake),
        ],
    ],
    .jealousy: [
        [
            scriptLine("$A", "Getting petted a lot lately, huh.", 3500, 0),
            scriptLine("$B", "...is that a problem?", 3000, 700),
            scriptLine("$A", "No. It's FINE.", 2500, 500, .vibrate),
        ],
        [
            scriptLine("$A", "Teacher's pet.", 2500, 0, .headshake),
            scriptLine("$B", "You're just jealous of my fluff.", 3500, 700, .bounce),
        ],
    ],
    .mediation: [
        [
            scriptLine("$M", "Okay. Both of you. Here. Now.", 3500, 0),
            scriptLine("$A", "Only if THEY apologize.", 3000, 700),
            scriptLine("$B", "ME?!", 2000, 400, .vibrate),
            scriptLine("$M", "*long, tired sheep sigh*", 3000, 600),
        ],
        [
            scriptLine("$M", "This feud is exhausting the whole flock.", 4000, 0),
            scriptLine("$A", "...they started it.", 2500, 700),
            scriptLine("$M", "I don't care. Hug it out. Metaphorically.", 4000, 600, .headshake),
        ],
    ],
    .reconciliation: [
        [
            scriptLine("$A", "Look... I said things.", 3000, 0),
            scriptLine("$B", "We both said things.", 3000, 700),
            scriptLine("$A", "Your wool looked fine that day.", 3500, 600),
            scriptLine("$B", "...thanks. Yours too.", 3000, 500, .bounce),
        ],
    ],
    .inseparable: [
        [
            scriptLine("$A", "Best flockmate?", 2500, 0),
            scriptLine("$B", "Best flockmate.", 2500, 500, .bounce),
        ],
        [
            scriptLine("$A", "We should synchronize our grazing.", 3500, 0),
            scriptLine("$B", "Way ahead of you.", 2500, 600, .bounce),
        ],
    ],
]

func pickDramaScript(_ kind: DramaScriptKind, _ idA: String, _ idB: String,
                     _ mediatorId: String? = nil) -> ConversationScript {
    let pool = SCRIPTS[kind]!
    let template = pool[SimRandom.int(pool.count)]
    return template.map { l in
        var out = l
        out.speakerId =
            l.speakerId == "$A" ? idA :
            l.speakerId == "$B" ? idB :
            l.speakerId == "$M" ? (mediatorId ?? idA) :
            l.speakerId
        return out
    }
}
