package com.litter.android.state

import org.junit.Assert.assertEquals
import org.junit.Test
import uniffi.codex_mobile_client.AbsolutePath
import uniffi.codex_mobile_client.AppUserInput

class AppComposerPayloadTest {
    @Test
    fun turnStartParamsPrependsTextAndPreservesAdditionalInputs() {
        val payload =
            AppComposerPayload(
                text = "Describe this",
                additionalInputs =
                    listOf(
                        AppUserInput.Skill(name = "swiftui-pro", path = AbsolutePath("/Users/sigkitten/.codex/skills/swiftui-pro/SKILL.md")),
                        ComposerImageAttachment(
                            data = byteArrayOf(0x01, 0x02),
                            mimeType = "image/png",
                        ).toUserInput(),
                        AppUserInput.Mention(name = "helper", path = "app://agent"),
                    ),
            )

        val params = payload.toAppStartTurnRequest(threadId = "thread-123")

        assertEquals(4, params.input.size)

        val textInput = params.input[0] as AppUserInput.Text
        assertEquals("Describe this", textInput.text)

        val skillInput = params.input[1] as AppUserInput.Skill
        assertEquals("swiftui-pro", skillInput.name)
        assertEquals("/Users/sigkitten/.codex/skills/swiftui-pro/SKILL.md", skillInput.path.value)

        val imageInput = params.input[2] as AppUserInput.Image
        assertEquals("data:image/png;base64,AQI=", imageInput.url)

        val mentionInput = params.input[3] as AppUserInput.Mention
        assertEquals("helper", mentionInput.name)
        assertEquals("app://agent", mentionInput.path)
    }

    @Test
    fun turnStartParamsAllowsAttachmentOnlyPayloads() {
        val payload =
            AppComposerPayload(
                text = "",
                additionalInputs =
                    listOf(
                        ComposerImageAttachment(
                            data = byteArrayOf(0x0A, 0x0B),
                            mimeType = "image/jpeg",
                        ).toUserInput(),
                    ),
            )

        val params = payload.toAppStartTurnRequest(threadId = "thread-456")

        assertEquals(1, params.input.size)
        val imageInput = params.input.single() as AppUserInput.Image
        assertEquals("data:image/jpeg;base64,Cgs=", imageInput.url)
    }
}
