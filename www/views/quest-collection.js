pp.views.QuestCollection = Backbone.View.extend({

    tag: 'div',

    template: _.template($('#template-quest-collection').text()),

    initialize: function () {
        this.options.quests.on('reset', this.onReset, this);
        this.options.quests.on('update', this.render, this);
        this.render(); // FIXME - is this really necessary?
    },

    render: function (collection) {
        this.$el.html(this.template({hasQuests: this.options.quests.models.length}));
        return this;
    },

    onAdd: function (quest) {
        var view = new pp.views.Quest({model: quest});
        this.$el.find('.quests-list').append(view.render().el);
    },

    onReset: function () {
        this.options.quests.each(this.onAdd, this);
    }
});