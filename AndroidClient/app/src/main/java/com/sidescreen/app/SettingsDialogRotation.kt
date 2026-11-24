package com.sidescreen.app

internal fun refreshOpenSettingsDialog(
    isShowing: Boolean,
    dismiss: () -> Unit,
    reopen: () -> Unit,
) {
    if (!isShowing) return
    dismiss()
    reopen()
}
