package com.litter.android.ui.apps

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.litter.android.ui.conversation.WidgetBridge
import com.litter.android.ui.conversation.pushWidgetContent
import com.litter.android.ui.conversation.wrapWidgetHtml
import com.litter.android.ui.conversation.escapeJsString
import com.sigkitten.litter.android.R

private const val MINIGAME_STUBS = """
window.sendPrompt = function(){};
window.saveAppState = function(){};
window.loadAppState = function(){ return null; };
window.structuredResponse = function(){ return Promise.reject(new Error('disabled in minigame mode')); };
// Defence-in-depth: kill double-tap-to-zoom even when WebView setSupportZoom(false)
// fails to suppress it on some OEM builds.
(function(){
  var meta = document.querySelector('meta[name="viewport"]');
  if (!meta) {
    meta = document.createElement('meta');
    meta.name = 'viewport';
    document.head.appendChild(meta);
  }
  meta.content = 'width=device-width, initial-scale=1, maximum-scale=1, minimum-scale=1, user-scalable=no';
  var style = document.createElement('style');
  style.textContent = 'html,body{touch-action:manipulation;-webkit-tap-highlight-color:transparent;}';
  document.head.appendChild(style);
  var lastTouchEnd = 0;
  document.addEventListener('touchend', function(e){
    var now = Date.now();
    if (now - lastTouchEnd <= 300) e.preventDefault();
    lastTouchEnd = now;
  }, { passive: false });
})();
"""

/**
 * A WebView that renders widget HTML in "minigame mode": bridge callbacks for
 * sendPrompt / saveAppState / loadAppState / structuredResponse are no-ops both
 * in JS (stub globals injected before user script) and at the native bridge
 * layer (those interfaces are never registered). openLink still works.
 *
 * Pass [widgetHtml] as the HTML fragment to render. The shell wraps it via
 * [wrapWidgetHtml] exactly as [AppModeWebView] does.
 */
// Lint cannot resolve @JavascriptInterface through this remembered Kotlin bridge;
// WidgetBridge's complete public JS surface is explicitly annotated.
@SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
@Composable
fun MinigameWebView(
    widgetHtml: String,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current

    val widgetBridge = remember {
        WidgetBridge(
            onHeight = {},
            onSendPrompt = {},
            onOpenLink = { url ->
                try {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                } catch (_: Exception) {}
            },
            onReady = {},
        )
    }

    val shell = remember(widgetHtml) {
        wrapWidgetHtml(widgetHtml = "", appState = null)
    }

    AndroidView(
        factory = { ctx ->
            WebView(ctx).apply {
                setBackgroundColor(android.graphics.Color.TRANSPARENT)
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                settings.loadsImagesAutomatically = true
                settings.setSupportZoom(false)
                settings.builtInZoomControls = false
                settings.displayZoomControls = false
                overScrollMode = WebView.OVER_SCROLL_NEVER
                // Only register openLink/height/ready — not sendPrompt/saveAppState/structuredResponse.
                addJavascriptInterface(widgetBridge, WidgetBridge.INTERFACE_NAME)
                webViewClient = object : WebViewClient() {
                    override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                        super.onPageStarted(view, url, favicon)
                        view?.evaluateJavascript(MINIGAME_STUBS, null)
                    }

                    override fun onPageFinished(view: WebView?, url: String?) {
                        super.onPageFinished(view, url)
                        if (view == null) return
                        view.setTag(R.id.widget_webview_shell_ready, true)
                        val pending = view.getTag(R.id.widget_webview_pending_html) as? String
                        if (pending != null) {
                            view.setTag(R.id.widget_webview_pending_html, null)
                            pushWidgetContent(view, pending, runScripts = true)
                        }
                    }

                    override fun shouldOverrideUrlLoading(
                        view: WebView?,
                        request: WebResourceRequest?,
                    ): Boolean {
                        val url = request?.url?.toString().orEmpty()
                        if (url.isBlank() || url.startsWith("about:")) return false
                        return try {
                            ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            true
                        } catch (_: Exception) {
                            false
                        }
                    }
                }
                loadDataWithBaseURL("https://widget.local/", shell, "text/html", "utf-8", null)
            }
        },
        modifier = modifier,
        update = { webView ->
            val lastEscaped = webView.getTag(R.id.widget_webview_last_escaped) as? String
            val escaped = escapeJsString(widgetHtml)
            if (escaped == lastEscaped) return@AndroidView
            webView.setTag(R.id.widget_webview_last_escaped, escaped)
            val shellReady = webView.getTag(R.id.widget_webview_shell_ready) as? Boolean ?: false
            if (!shellReady) {
                webView.setTag(R.id.widget_webview_pending_html, widgetHtml)
            } else {
                pushWidgetContent(webView, widgetHtml, runScripts = true)
            }
        },
    )
}
