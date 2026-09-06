package com.sidescreen.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsDialogRotationTest {
    @Test
    fun openDialogIsDismissedAndReopenedAfterConfigurationChange() {
        var dismissed = false
        var reopened = false

        refreshOpenSettingsDialog(
            isShowing = true,
            dismiss = { dismissed = true },
            reopen = { reopened = true },
        )

        assertTrue("The old orientation hierarchy must be dismissed", dismissed)
        assertTrue("The dialog must be reinflated for the new orientation", reopened)
    }

    @Test
    fun closedDialogStaysClosedAfterConfigurationChange() {
        var dismissed = false
        var reopened = false

        refreshOpenSettingsDialog(
            isShowing = false,
            dismiss = { dismissed = true },
            reopen = { reopened = true },
        )

        assertFalse("A closed dialog must not be dismissed again", dismissed)
        assertFalse("Rotation must not open settings unexpectedly", reopened)
    }
}
