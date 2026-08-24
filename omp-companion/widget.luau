-- OMP Companion bar widget — a mic button that opens the panel.

barWidget.setGlyph("mic")
barWidget.setTooltip(noctalia.tr("panel.title"))

function onClick()
    noctalia.togglePanel("weinguyen/omp-companion:panel")
end
