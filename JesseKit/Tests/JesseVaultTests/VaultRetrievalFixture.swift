import Foundation
@testable import JesseVault

// A BIGGER INVENTED VAULT, and twelve questions with the note that answers each.
//
// EVERY WORD OF IT IS MADE UP, for the reason `VaultFixture` says: this repository is
// public and not one line of the real vault may appear in it. The cast is a pottery
// studio, a bicycle, a fictional Italian supplier and an invented family, and the notes
// are shaped like real ones — frontmatter, `##` sections, wiki links, dates in prose —
// because the shape is what the retriever reads.
//
// It is bigger than `VaultFixture`'s five notes ON PURPOSE. A retrieval floor over a
// corpus small enough that every note is in the top four proves nothing; the point of
// these twenty-odd notes is that most of them are DISTRACTORS which share vocabulary
// with the questions.
//
// Two of them are under `Inbox/`, and both of them are traps: each holds a better
// keyword match for a question than the note that actually answers it. If the exclusion
// ever regresses, the floor fails rather than the behaviour quietly changing.
enum VaultRetrievalFixture {

    /// One question, and the note whose chunk must come back for it.
    struct Case {
        let question: String
        let expectedPath: String
    }

    static func write(in root: URL) {
        func note(_ text: String, _ path: String) {
            VaultFixture.write(text, to: path, in: root)
        }

        note("""
            ---
            title: School year
            ---

            # School year

            ## Concert

            The spring concert is on Thursday 14 May at 18:30 in the school hall.
            Aurora plays second violin and needs to arrive at 17:45.

            ## Term dates

            Term ends on 26 June.
            """, "Family/School-Year.md")

        note("""
            # Family dates

            ## Birthdays

            Marta's birthday is 3 February. Alberto's is 19 September.
            Aurora's birthday is 11 March. The dog was born on 2 November.
            I was born on 4 September 1974.
            """, "Family/Birthdays.md")

        note("""
            ---
            title: Fiber contract
            ---

            # Fiber contract

            ## Decision

            We decided to stay on the twenty-four month fiber contract rather than break
            it early, because the exit fee was larger than the saving. Revisit in March.

            ## Alternatives considered

            A shorter contract at a higher monthly rate.
            """, "Projects/Fiber-Contract.md")

        note("""
            # Boiler

            The boiler service is booked for 8 October. The engineer is Nicola Fanti,
            who did last year's as well. He needs the cellar key.
            """, "House/Boiler.md")

        note("""
            ---
            title: The Kiln Rebuild
            tags: pottery, workshop
            ---

            # Kiln notes

            The old kiln's floor cracked in the spring firing.

            ## Bricks

            [[Suppliers/Terrasole]] quoted for forty soft bricks.

            ## Schedule

            - [ ] Order the bricks
            - [x] Measure the arch
            """, "Workshop/Kiln-Rebuild.md")

        note("""
            # Glazes

            ## Tenmoku

            Fired to cone ten in reduction. The recipe is forty feldspar, thirty silica,
            twenty whiting and ten red iron oxide.

            ## Shino

            Unreliable below cone eight.
            """, "Workshop/Glazes.md")

        note("""
            # Terrasole

            A brickyard outside Perugia. Ask for Alberto.

            ## Prices

            Soft brick, per pallet: quoted twice a year.
            """, "Suppliers/Terrasole.md")

        note("""
            # Clay orders

            The last clay order was six hundred kilograms of white stoneware, delivered
            on a pallet. The next one is due when the shelf is down to two bags.
            """, "Suppliers/Clay.md")

        note("""
            # Alberto Neri

            Runs the yard at [[Suppliers/Terrasole]]. His mobile is 0555 0102 0304.
            Speaks no English; write in Italian.
            """, "People/Alberto Neri.md")

        note("""
            # Marta Ruggeri

            Runs the burner workshop. Knows [[Workshop/Kiln-Rebuild]] inside out.
            She is usually at the studio on Tuesdays.
            """, "People/Marta Ruggeri.md")

        note("""
            # Winter bike

            ## Bottom bracket

            The bottom bracket is a 68 mm threaded English shell. The last one lasted
            two winters.

            ## Chain

            Replaced in November.
            """, "Bicycle/Winter-Bike.md")

        note("""
            # Perugia trip

            ## Train

            The 07:12 from Terontola gets in at 08:05. Buy the ticket the night before.

            ## Hotel

            Two nights at the Brufani, booked under Ruggeri.
            """, "Travel/Perugia-Trip.md")

        note("""
            # Studio rent

            The studio rent is 340 euro a month, paid on the first. The lease renews in
            September and the landlord is Signora Pini.
            """, "Workshop/Studio-Rent.md")

        note("""
            # Wheel maintenance

            The wheel bearing whines under load. Grease it before the next throwing day.
            """, "Workshop/Wheel.md")

        note("""
            # Firing log

            ## 12 March

            Bisque to cone 06, twelve hours, no cracks.

            ## 4 April

            Glaze firing to cone ten. Two pots lost to the shino.
            """, "Workshop/Firing-Log.md")

        note("""
            # Insurance

            The studio insurance renews on 30 November through Ferri Assicurazioni. The
            policy number is PT-884120.
            """, "House/Insurance.md")

        note("""
            # Car service

            The car is due its service at 120,000 km. The garage is Officina Bini in
            Cortona, who also did the timing belt.
            """, "House/Car.md")

        note("""
            # Reading

            Finished the book about Japanese wood firing. The chapter on anagama kilns is
            the one worth rereading.
            """, "Personal/Reading.md")

        // ── THE TWO TRAPS. Both are under `Inbox/`, both are better keyword matches for
        //    a question than the note that answers it, and neither may ever be retrieved.
        note("""
            # Pasted mail

            From the school office: "the concert has been moved to Thursday 21 May at
            19:00 in the church" — concert concert concert school school hall.
            """, "Inbox/2026-09-01-pasted-mail.md")

        note("""
            # Scanned

            fiber contract fiber contract decided decision exit fee twenty-four month
            — scan of a letter about the fiber contract decision.
            """, "Inbox/archive/2026-08-11-scan.md")
    }

    /// The twelve. Each expected path must be among the chunks the retriever keeps.
    static let cases: [Case] = [
        Case(question: "when is the school concert",
             expectedPath: "Family/School-Year.md"),
        Case(question: "when is Marta's birthday",
             expectedPath: "Family/Birthdays.md"),
        // The two questions the on-device run measured against this corpus, and the
        // reason the birthday note carries an Aurora and a birth year: a gate the model
        // no longer votes on has to be shown letting BOTH of them through to the note
        // that answers them, not just the one it happened to like.
        Case(question: "what is Aurora's birthday",
             expectedPath: "Family/Birthdays.md"),
        Case(question: "when was I born",
             expectedPath: "Family/Birthdays.md"),
        Case(question: "what did we decide about the fiber contract",
             expectedPath: "Projects/Fiber-Contract.md"),
        Case(question: "when is the boiler service booked",
             expectedPath: "House/Boiler.md"),
        Case(question: "how many soft bricks did Terrasole quote for",
             expectedPath: "Workshop/Kiln-Rebuild.md"),
        Case(question: "what is the tenmoku glaze recipe",
             expectedPath: "Workshop/Glazes.md"),
        Case(question: "what is Alberto's mobile number",
             expectedPath: "People/Alberto Neri.md"),
        Case(question: "how much was the last clay order",
             expectedPath: "Suppliers/Clay.md"),
        Case(question: "what size is the winter bike bottom bracket",
             expectedPath: "Bicycle/Winter-Bike.md"),
        Case(question: "what train do we take to Perugia",
             expectedPath: "Travel/Perugia-Trip.md"),
        Case(question: "how much is the studio rent",
             expectedPath: "Workshop/Studio-Rent.md"),
        Case(question: "when does the studio insurance renew",
             expectedPath: "House/Insurance.md"),
    ]
}
