package com.sidescreen.app

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class MainActivityManifestTest {
    @Test
    fun handlesAllRotationRelatedSizeChangesWithoutActivityRecreation() {
        val manifest = findManifest()
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(manifest)
        val activities = document.getElementsByTagName("activity")
        val mainActivity =
            (0 until activities.length)
                .map { activities.item(it) }
                .first { it.attributes.getNamedItem("android:name")?.nodeValue == ".MainActivity" }
        val handledChanges =
            mainActivity.attributes
                .getNamedItem("android:configChanges")
                .nodeValue
                .split('|')
                .toSet()
        val requiredChanges =
            setOf(
                "orientation",
                "screenSize",
                "screenLayout",
                "smallestScreenSize",
            )

        assertTrue(
            "MainActivity must handle all rotation-related size changes to keep streaming alive",
            handledChanges.containsAll(requiredChanges),
        )
    }

    private fun findManifest(): File {
        val workingDirectory = File(System.getProperty("user.dir") ?: error("user.dir is not set"))
        return listOf(
            workingDirectory.resolve("app/src/main/AndroidManifest.xml"),
            workingDirectory.resolve("src/main/AndroidManifest.xml"),
        ).firstOrNull(File::isFile)
            ?: error("AndroidManifest.xml not found from $workingDirectory")
    }
}
