define ["models/current-user", "views/user/current"], (currentUser, View) ->
    describe "current user:", ->
        describe "notifications icon", ->
            model = undefined
            beforeEach ->
                model = currentUser.clone()
                model.set
                    _id: "513b9a2f01e3b87329000000"
                    registered: 1
                    login: "somebody"
                    rp:
                        chaos: 3
                    settings: {}
                    notifications: []
                    realms: ["chaos"]

            describe "when there are no notificatons", ->
                it "no icon is shown", ->
                    view = new View(model: model)
                    view.render()
                    expect(view.$el.find(".current-user-notifications-icon").length).toEqual 0

            describe "when there are some notificatons", ->
                it "icon is shown", ->
                    model.set "notifications", [
                        params: "preved"
                        ts: 1362860591
                        _id: "513b9a2f01e3b87329000000"
                        user: "somebody"
                        type: "shout"
                    ,
                        params: "medved"
                        ts: 1362860591
                        _id: "513b9a2f01e3b87329000000"
                        user: "somebody"
                        type: "shout"
                    ]
                    view = new View(model: model)
                    view.render()
                    expect(view.$(".current-user-notifications-icon").length).toEqual 1

            describe "new quest link", ->
                view = undefined
                beforeEach ->
                    view = new View(model: model)
                    view.render()
                it "initial value", ->
                    expect(view.$(".quest-add-link").attr "href").toEqual "/quest/add"

                it "changed on setRealm", ->
                    view.setRealm('europe')
                    expect(view.$(".quest-add-link").attr "href").toEqual "/realm/europe/quest/add"

                it "changed on setRealm(null)", ->
                    view.setRealm(null)
                    expect(view.$(".quest-add-link").attr "href").toEqual "/quest/add"
