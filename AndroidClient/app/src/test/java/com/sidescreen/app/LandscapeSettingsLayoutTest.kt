package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import org.w3c.dom.Node
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class LandscapeSettingsLayoutTest {
    private val androidNamespace = "http://schemas.android.com/apk/res/android"
    private val runtimeRequiredIds =
        listOf(
            "showStatsSwitch",
            "hideSettingsSwitch",
            "opacitySlider",
            "opacityValue",
            "resetPositionButton",
            "resetSettingsButton",
            "disconnectSettingsButton",
            "closeButton",
            "cornerTopLeft",
            "positionTopCenter",
            "cornerTopRight",
            "positionCenterLeft",
            "positionCenterRight",
            "cornerBottomLeft",
            "positionBottomCenter",
            "cornerBottomRight",
        )

    @Test
    fun landscapeLayoutGroupsSettingsAndKeepsActionsOutsideScrollingContent() {
        val layout = locateLandscapeLayout()
        assertTrue("Landscape settings layout must exist", layout.isFile)

        val document =
            DocumentBuilderFactory
                .newInstance()
                .apply { isNamespaceAware = true }
                .newDocumentBuilder()
                .parse(layout)

        val columns = findById(document.documentElement, "settingsColumns")
        assertNotNull("Landscape settings must have a grouped columns container", columns)
        assertEquals("horizontal", columns!!.getAttributeNS(androidNamespace, "orientation"))

        val overlayColumn = findById(document.documentElement, "overlaySettingsColumn")
        val buttonColumn = findById(document.documentElement, "buttonSettingsColumn")
        assertNotNull("Overlay controls must form the first column", overlayColumn)
        assertNotNull("Settings-button controls must form the second column", buttonColumn)
        assertTrue("Overlay controls must be inside the columns container", isDescendantOf(overlayColumn!!, columns))
        assertTrue("Button controls must be inside the columns container", isDescendantOf(buttonColumn!!, columns))
        val overlayScroller = findAncestorNamed(overlayColumn, "ScrollView")
        val buttonScroller = findAncestorNamed(buttonColumn, "ScrollView")
        assertNotNull("Overlay controls must scroll independently when space is constrained", overlayScroller)
        assertNotNull("Button controls must scroll independently when space is constrained", buttonScroller)
        assertNotSame("Each settings group must have its own scroller", overlayScroller, buttonScroller)

        val actionBar = findById(document.documentElement, "settingsActionBar")
        val disconnect = findById(document.documentElement, "disconnectSettingsButton")
        val done = findById(document.documentElement, "closeButton")
        assertNotNull("Landscape settings must have a fixed action bar", actionBar)
        assertNotNull("Disconnect action must remain available", disconnect)
        assertNotNull("Done action must remain available", done)
        assertTrue("Disconnect must be in the fixed action bar", isDescendantOf(disconnect!!, actionBar!!))
        assertTrue("Done must be in the fixed action bar", isDescendantOf(done!!, actionBar))
        assertFalse("The fixed action bar must not scroll", hasAncestorNamed(actionBar, "ScrollView"))

        val portraitDocument = parseLayout(locatePortraitLayout())
        runtimeRequiredIds.forEach { id ->
            assertNotNull(
                "Portrait layout must retain runtime control $id",
                findById(portraitDocument.documentElement, id),
            )
            assertNotNull("Landscape layout must retain runtime control $id", findById(document.documentElement, id))
        }
    }

    @Test
    fun landscapeInteractiveControlsHaveAccessibleLabelsAndTouchTargets() {
        val document = parseLayout(locateLandscapeLayout())
        val directionalIds =
            listOf(
                "cornerTopLeft",
                "positionTopCenter",
                "cornerTopRight",
                "positionCenterLeft",
                "positionCenterRight",
                "cornerBottomLeft",
                "positionBottomCenter",
                "cornerBottomRight",
            )

        directionalIds.forEach { id ->
            val button = requireNotNull(findById(document.documentElement, id))
            val height = button.getAttributeNS(androidNamespace, "layout_height").removeSuffix("dp").toInt()
            assertTrue("$id must be at least 48dp tall", height >= 48)
            assertTrue(
                "$id must have a semantic accessibility label",
                button.getAttributeNS(androidNamespace, "contentDescription").isNotBlank(),
            )
        }

        listOf("showStatsSwitch", "hideSettingsSwitch", "opacitySlider").forEach { id ->
            val control = requireNotNull(findById(document.documentElement, id))
            assertTrue(
                "$id must have a semantic accessibility label",
                control.getAttributeNS(androidNamespace, "contentDescription").isNotBlank(),
            )
        }
    }

    private fun locateLandscapeLayout(): File {
        val workingDirectory = File(requireNotNull(System.getProperty("user.dir")))
        val candidates =
            listOf(
                File(workingDirectory, "app/src/main/res/layout-land/dialog_settings.xml"),
                File(workingDirectory, "src/main/res/layout-land/dialog_settings.xml"),
            )
        return candidates.firstOrNull(File::exists) ?: candidates.first()
    }

    private fun locatePortraitLayout(): File {
        val workingDirectory = File(requireNotNull(System.getProperty("user.dir")))
        val candidates =
            listOf(
                File(workingDirectory, "app/src/main/res/layout/dialog_settings.xml"),
                File(workingDirectory, "src/main/res/layout/dialog_settings.xml"),
            )
        return candidates.firstOrNull(File::exists) ?: candidates.first()
    }

    private fun parseLayout(layout: File) =
        DocumentBuilderFactory
            .newInstance()
            .apply { isNamespaceAware = true }
            .newDocumentBuilder()
            .parse(layout)

    private fun findById(
        root: Element,
        id: String,
    ): Element? {
        if (root.getAttributeNS(androidNamespace, "id").endsWith("/$id")) {
            return root
        }
        val children = root.childNodes
        for (index in 0 until children.length) {
            val child = children.item(index)
            if (child is Element) {
                findById(child, id)?.let { return it }
            }
        }
        return null
    }

    private fun isDescendantOf(
        node: Node,
        ancestor: Node,
    ): Boolean {
        var parent = node.parentNode
        while (parent != null) {
            if (parent == ancestor) return true
            parent = parent.parentNode
        }
        return false
    }

    private fun hasAncestorNamed(
        node: Node,
        name: String,
    ): Boolean = findAncestorNamed(node, name) != null

    private fun findAncestorNamed(
        node: Node,
        name: String,
    ): Node? {
        var parent = node.parentNode
        while (parent != null) {
            if (parent.nodeName.substringAfterLast('.') == name) return parent
            parent = parent.parentNode
        }
        return null
    }
}
