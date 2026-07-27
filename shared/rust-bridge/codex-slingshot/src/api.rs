use std::sync::{Arc, RwLock};

use reqwest::Client;
use reqwest::header::{
    ACCEPT, ACCEPT_LANGUAGE, AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderName, HeaderValue,
    USER_AGENT,
};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tracing::{info, warn};
use url::Url;

use crate::device_key::DeviceKeyEnrollment;
use crate::enrollment::{EnrollmentStore, SlingshotControllerSession};
use crate::envelope::RemoteControlEnvelope;
use crate::errors::SlingshotApiError;
use crate::types::{
    ClientEnrollmentFinishRequest, ClientEnrollmentResponse, ClientEnrollmentTokenResponse,
    ClientRefreshFinishRequest, ClientRefreshStartRequest, EnvironmentUpdateRequest,
    LegacyClientEnrollmentResponse, SlingshotEnvironment, ThreadsPage,
};

const REMOTE_CONTROL_PROTOCOL_VERSION: &str = "3";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SlingshotRoute {
    Codex,
    Wham,
}

#[derive(Clone, Debug)]
pub struct SlingshotConfig {
    pub base_url: Url,
    pub auth_token: String,
    pub user_agent: String,
    pub account_id: Option<String>,
    pub originator: Option<String>,
    pub client_id: Option<String>,
}

#[derive(Clone)]
pub struct SlingshotApi {
    http: Client,
    cfg: SlingshotConfig,
    route: SlingshotRoute,
    client_id: Arc<RwLock<Option<String>>>,
    client_session_token: Arc<RwLock<Option<String>>>,
    device_key: Arc<RwLock<Option<DeviceKeyEnrollment>>>,
    controller_session: Arc<RwLock<Option<SlingshotControllerSession>>>,
}

impl SlingshotApi {
    pub fn new(cfg: SlingshotConfig) -> Self {
        Self::new_with_route(cfg, SlingshotRoute::Codex)
    }

    pub fn new_wham(cfg: SlingshotConfig) -> Self {
        Self::new_with_route(cfg, SlingshotRoute::Wham)
    }

    fn new_with_route(cfg: SlingshotConfig, route: SlingshotRoute) -> Self {
        let SlingshotConfig {
            base_url,
            auth_token,
            user_agent,
            account_id,
            originator,
            client_id,
        } = cfg;
        let cfg = SlingshotConfig {
            base_url: normalize_base_url(base_url),
            auth_token,
            user_agent,
            account_id,
            originator,
            client_id,
        };
        Self {
            http: Client::new(),
            route,
            client_id: Arc::new(RwLock::new(cfg.client_id.clone())),
            client_session_token: Arc::new(RwLock::new(None)),
            device_key: Arc::new(RwLock::new(None)),
            controller_session: Arc::new(RwLock::new(None)),
            cfg,
        }
    }

    pub fn requires_client_session_token(&self) -> bool {
        matches!(self.route, SlingshotRoute::Codex)
    }

    pub(crate) fn requires_device_key_handshake(&self) -> bool {
        matches!(self.route, SlingshotRoute::Codex)
    }

    pub fn client_id(&self) -> Option<String> {
        match self.client_id.read() {
            Ok(guard) => guard.clone(),
            Err(error) => error.into_inner().clone(),
        }
    }

    pub fn set_client_id(&self, client_id: impl Into<String>) {
        match self.client_id.write() {
            Ok(mut guard) => *guard = Some(client_id.into()),
            Err(error) => *error.into_inner() = Some(client_id.into()),
        }
    }

    pub fn client_session_token(&self) -> Option<String> {
        match self.client_session_token.read() {
            Ok(guard) => guard.clone(),
            Err(error) => error.into_inner().clone(),
        }
    }

    fn set_client_session_token(&self, token: impl Into<String>) {
        let token = token.into();
        match self.client_session_token.write() {
            Ok(mut guard) => *guard = Some(token),
            Err(error) => *error.into_inner() = Some(token),
        }
    }

    pub(crate) fn device_key(&self) -> Option<DeviceKeyEnrollment> {
        match self.device_key.read() {
            Ok(guard) => guard.clone(),
            Err(error) => error.into_inner().clone(),
        }
    }

    fn set_device_key(&self, device_key: DeviceKeyEnrollment) {
        match self.device_key.write() {
            Ok(mut guard) => *guard = Some(device_key),
            Err(error) => *error.into_inner() = Some(device_key),
        }
    }

    pub fn controller_session(&self) -> Option<SlingshotControllerSession> {
        match self.controller_session.read() {
            Ok(guard) => guard.clone(),
            Err(error) => error.into_inner().clone(),
        }
    }

    pub fn restore_controller_session(&self, session: SlingshotControllerSession) {
        self.set_client_id(session.client_id.clone());
        self.set_client_session_token(session.remote_control_token.clone());
        self.set_device_key(session.device_key.clone());
        match self.controller_session.write() {
            Ok(mut guard) => *guard = Some(session),
            Err(error) => *error.into_inner() = Some(session),
        }
    }

    pub async fn ensure_enrolled<S>(&self, store: &S) -> Result<String, SlingshotApiError>
    where
        S: EnrollmentStore + ?Sized,
    {
        if let Some(client_id) = self.client_id() {
            return Ok(client_id);
        }
        if let Some(client_id) = store.load().await? {
            self.set_client_id(client_id.clone());
            return Ok(client_id);
        }
        let response = self.enroll_start().await?;
        store.save(&response.client_id).await?;
        Ok(response.client_id)
    }

    /// `POST /codex/remote/control/client/enroll/start`
    pub async fn enroll_start(&self) -> Result<ClientEnrollmentResponse, SlingshotApiError> {
        let url = self.path(&["client", "enroll", "start"])?;
        log_http_request(
            "POST",
            &url,
            "Slingshot client enrollment start",
            Some("{}"),
        );
        let response = self
            .http
            .post(url)
            .headers(self.headers(None, false)?)
            .json(&serde_json::json!({}))
            .send()
            .await?;
        let response = ensure_success(response, "Slingshot client enrollment").await?;
        let response: ClientEnrollmentResponse =
            decode_json_response(response, "Slingshot client enrollment").await?;
        info!(
            target: "codex_slingshot",
            client_id = %response.client_id,
            account_user_id = %response.account_user_id,
            challenge_id = %response.device_key_challenge.challenge_id,
            challenge_target_origin = %response.device_key_challenge.target_origin,
            challenge_target_path = %response.device_key_challenge.target_path,
            challenge_has_device_identity_hash = response.device_key_challenge.device_identity_hash.is_some(),
            "slingshot enrollment start decoded"
        );
        self.set_client_id(response.client_id.clone());
        Ok(response)
    }

    /// `POST /wham/remote/control/client/enroll`
    pub async fn enroll_legacy_client(
        &self,
    ) -> Result<LegacyClientEnrollmentResponse, SlingshotApiError> {
        let url = self.path(&["client", "enroll"])?;
        log_http_request("POST", &url, "Slingshot legacy client enrollment", None);
        let response = self
            .http
            .post(url)
            .headers(self.headers(None, false)?)
            .send()
            .await?;
        let response = ensure_success(response, "Slingshot legacy client enrollment").await?;
        let response: LegacyClientEnrollmentResponse =
            decode_json_response(response, "Slingshot legacy client enrollment").await?;
        self.set_client_id(response.client_id.clone());
        info!(
            target: "codex_slingshot",
            client_id = %response.client_id,
            "slingshot legacy enrollment decoded"
        );
        Ok(response)
    }

    pub async fn enroll_with_step_up_token(
        &self,
        step_up_token: &str,
    ) -> Result<ClientEnrollmentTokenResponse, SlingshotApiError> {
        info!(target: "codex_slingshot", "slingshot enrollment flow starting");
        let start = self.enroll_start().await?;
        let device_key =
            DeviceKeyEnrollment::generate(start.account_user_id.clone(), start.client_id.clone())?;
        info!(
            target: "codex_slingshot",
            client_id = %start.client_id,
            account_user_id = %start.account_user_id,
            device_key_id = %device_key.key_id,
            device_identity_hash = %device_key.device_identity_hash()?,
            "slingshot generated device key"
        );
        let (target_origin, target_path) = self.expected_target("client/enroll/finish")?;
        info!(
            target: "codex_slingshot",
            expected_target_origin = %target_origin,
            expected_target_path = %target_path,
            challenge_target_origin = %start.device_key_challenge.target_origin,
            challenge_target_path = %start.device_key_challenge.target_path,
            "slingshot signing enrollment challenge"
        );
        let proof = device_key.sign_enrollment_challenge(
            &start.device_key_challenge,
            &target_origin,
            &target_path,
            false,
        )?;
        let finish = self
            .enroll_finish(&ClientEnrollmentFinishRequest {
                client_id: start.client_id,
                step_up_token: step_up_token.trim().to_string(),
                device_identity: device_key.device_identity(),
                device_key_proof: proof,
            })
            .await?;
        let session = SlingshotControllerSession::from_finish(device_key, finish.clone());
        self.restore_controller_session(session);
        info!(
            target: "codex_slingshot",
            client_id = %finish.client_id,
            account_user_id = %finish.account_user_id,
            expires_at = finish.expires_at,
            scopes = ?finish.scopes,
            "slingshot enrollment flow finished"
        );
        Ok(finish)
    }

    pub async fn refresh_with_device_key(
        &self,
        session: &SlingshotControllerSession,
    ) -> Result<ClientEnrollmentTokenResponse, SlingshotApiError> {
        info!(
            target: "codex_slingshot",
            client_id = %session.client_id,
            account_user_id = %session.account_user_id,
            expires_at = %session.expires_at,
            "slingshot controller token refresh starting"
        );
        self.set_client_id(session.client_id.clone());
        self.set_device_key(session.device_key.clone());
        let start = self.refresh_start(&session.client_id).await?;
        let (target_origin, target_path) = self.expected_target("client/refresh/finish")?;
        info!(
            target: "codex_slingshot",
            client_id = %start.client_id,
            account_user_id = %start.account_user_id,
            challenge_id = %start.device_key_challenge.challenge_id,
            expected_target_origin = %target_origin,
            expected_target_path = %target_path,
            challenge_target_origin = %start.device_key_challenge.target_origin,
            challenge_target_path = %start.device_key_challenge.target_path,
            "slingshot signing controller refresh challenge"
        );
        let proof = session.device_key.sign_enrollment_challenge(
            &start.device_key_challenge,
            &target_origin,
            &target_path,
            true,
        )?;
        let finish = self
            .refresh_finish(&ClientRefreshFinishRequest {
                client_id: session.client_id.clone(),
                device_key_proof: proof,
            })
            .await?;
        let refreshed =
            SlingshotControllerSession::from_finish(session.device_key.clone(), finish.clone());
        self.restore_controller_session(refreshed);
        info!(
            target: "codex_slingshot",
            client_id = %finish.client_id,
            account_user_id = %finish.account_user_id,
            expires_at = finish.expires_at,
            scopes = ?finish.scopes,
            "slingshot controller token refresh finished"
        );
        Ok(finish)
    }

    /// `POST /codex/remote/control/client/enroll/finish`
    pub async fn enroll_finish(
        &self,
        request: &ClientEnrollmentFinishRequest,
    ) -> Result<ClientEnrollmentTokenResponse, SlingshotApiError> {
        let url = self.path(&["client", "enroll", "finish"])?;
        log_http_request(
            "POST",
            &url,
            "Slingshot client enrollment finish",
            Some(&sanitize_json_value(&serde_json::to_value(request)?)),
        );
        let response = self
            .http
            .post(url)
            .headers(self.headers(None, false)?)
            .json(request)
            .send()
            .await?;
        let response = ensure_success(response, "Slingshot client enrollment finish").await?;
        let response: ClientEnrollmentTokenResponse =
            decode_json_response(response, "Slingshot client enrollment finish").await?;
        self.set_client_id(response.client_id.clone());
        Ok(response)
    }

    /// `POST /codex/remote/control/client/refresh/start`
    pub async fn refresh_start(
        &self,
        client_id: &str,
    ) -> Result<ClientEnrollmentResponse, SlingshotApiError> {
        let url = self.path(&["client", "refresh", "start"])?;
        let body = ClientRefreshStartRequest {
            client_id: client_id.to_string(),
        };
        log_http_request(
            "POST",
            &url,
            "Slingshot client refresh start",
            Some(&sanitize_json_value(&serde_json::to_value(&body)?)),
        );
        let response = self
            .http
            .post(url)
            .headers(self.headers(None, false)?)
            .json(&body)
            .send()
            .await?;
        let response = ensure_success(response, "Slingshot client refresh start").await?;
        let response: ClientEnrollmentResponse =
            decode_json_response(response, "Slingshot client refresh start").await?;
        info!(
            target: "codex_slingshot",
            client_id = %response.client_id,
            account_user_id = %response.account_user_id,
            challenge_id = %response.device_key_challenge.challenge_id,
            challenge_target_origin = %response.device_key_challenge.target_origin,
            challenge_target_path = %response.device_key_challenge.target_path,
            challenge_has_device_identity_hash = response.device_key_challenge.device_identity_hash.is_some(),
            "slingshot client refresh start decoded"
        );
        self.set_client_id(response.client_id.clone());
        Ok(response)
    }

    /// `POST /codex/remote/control/client/refresh/finish`
    pub async fn refresh_finish(
        &self,
        request: &ClientRefreshFinishRequest,
    ) -> Result<ClientEnrollmentTokenResponse, SlingshotApiError> {
        let url = self.path(&["client", "refresh", "finish"])?;
        log_http_request(
            "POST",
            &url,
            "Slingshot client refresh finish",
            Some(&sanitize_json_value(&serde_json::to_value(request)?)),
        );
        let response = self
            .http
            .post(url)
            .headers(self.headers(None, false)?)
            .json(request)
            .send()
            .await?;
        let response = ensure_success(response, "Slingshot client refresh finish").await?;
        let response: ClientEnrollmentTokenResponse =
            decode_json_response(response, "Slingshot client refresh finish").await?;
        self.set_client_id(response.client_id.clone());
        Ok(response)
    }

    /// Backwards-compatible name for the first phase of client enrollment.
    pub async fn enroll(&self) -> Result<ClientEnrollmentResponse, SlingshotApiError> {
        self.enroll_start().await
    }

    /// `GET /codex/remote/control/environments`
    pub async fn list_environments(&self) -> Result<Vec<SlingshotEnvironment>, SlingshotApiError> {
        let url = self.path(&["environments"])?;
        log_http_request("GET", &url, "Slingshot environments", None);
        let response = self
            .http
            .get(url)
            .timeout(std::time::Duration::from_secs(10))
            .headers(self.headers(None, false)?)
            .send()
            .await?;
        let response = ensure_success(response, "Slingshot environments").await?;
        let envs = decode_json_response::<EnvironmentsResponse>(response, "Slingshot environments")
            .await?
            .into_vec();
        info!(
            target: "codex_slingshot",
            count = envs.len(),
            "slingshot environments decoded"
        );
        Ok(envs)
    }

    /// `PATCH /codex/remote/control/environments/{id}`
    pub async fn update_environment(
        &self,
        environment_id: &str,
        name: &str,
    ) -> Result<SlingshotEnvironment, SlingshotApiError> {
        let url = self.path(&["environments", environment_id])?;
        let body = EnvironmentUpdateRequest {
            name: name.to_string(),
        };
        log_http_request(
            "PATCH",
            &url,
            "Slingshot environment update",
            Some(&sanitize_json_value(&serde_json::to_value(&body)?)),
        );
        let response = self
            .http
            .patch(url)
            .headers(self.headers(None, false)?)
            .json(&body)
            .send()
            .await?;
        let response = ensure_success(response, "Slingshot environment update").await?;
        let env = decode_json_response(response, "Slingshot environment update").await?;
        Ok(env)
    }

    /// `DELETE /codex/remote/control/environments/{id}`
    pub async fn delete_environment(&self, environment_id: &str) -> Result<(), SlingshotApiError> {
        let url = self.path(&["environments", environment_id])?;
        log_http_request("DELETE", &url, "Slingshot environment delete", None);
        self.http
            .delete(url)
            .headers(self.headers(None, false)?)
            .send()
            .await
            .and_then(|response| response.error_for_status())?;
        Ok(())
    }

    /// `GET /codex/remote/control/environments/{id}/threads?cursor=...&limit=...`
    pub async fn list_environment_threads(
        &self,
        environment_id: &str,
        cursor: Option<&str>,
        limit: Option<u32>,
    ) -> Result<ThreadsPage, SlingshotApiError> {
        let mut url = self.path(&["environments", environment_id, "threads"])?;
        {
            let mut query = url.query_pairs_mut();
            if let Some(cursor) = cursor {
                query.append_pair("cursor", cursor);
            }
            if let Some(limit) = limit {
                query.append_pair("limit", &limit.to_string());
            }
        }
        log_http_request("GET", &url, "Slingshot environment threads", None);
        let response = self
            .http
            .get(url)
            .headers(self.headers(None, false)?)
            .send()
            .await?;
        let response = ensure_success(response, "Slingshot environment threads").await?;
        let page: ThreadsPage =
            decode_json_response(response, "Slingshot environment threads").await?;
        info!(
            target: "codex_slingshot",
            environment_id,
            count = page.data.len(),
            next_cursor = ?page.next_cursor,
            "slingshot environment threads decoded"
        );
        Ok(page)
    }

    /// `GET /codex/remote/control/environments?cursor=...`
    pub async fn subscribe(
        &self,
        resume_cursor: Option<&str>,
    ) -> Result<reqwest::Response, SlingshotApiError> {
        let mut url = self.path(&["environments"])?;
        if let Some(cursor) = resume_cursor {
            url.query_pairs_mut().append_pair("cursor", cursor);
        }
        log_http_request("GET", &url, "Slingshot subscribe", None);
        let response = self
            .http
            .get(url)
            .headers(self.headers(resume_cursor, true)?)
            .send()
            .await?;
        let response = ensure_success(response, "Slingshot subscribe").await?;
        Ok(response)
    }

    /// Best-known send path. Capture can refine this without changing callers.
    pub async fn send_envelope(
        &self,
        envelope: &RemoteControlEnvelope,
    ) -> Result<(), SlingshotApiError> {
        envelope.validate_outbound()?;
        let url = self.path(&["environments"])?;
        log_http_request(
            "POST",
            &url,
            "Slingshot envelope send",
            Some(&sanitize_json_value(&serde_json::to_value(envelope)?)),
        );
        let response = self
            .http
            .post(url)
            .headers(self.headers(None, false)?)
            .json(envelope)
            .send()
            .await?;
        ensure_success(response, "Slingshot envelope send").await?;
        Ok(())
    }

    pub(crate) fn websocket_request(
        &self,
        resume_cursor: Option<&str>,
    ) -> Result<tokio_tungstenite::tungstenite::http::Request<()>, SlingshotApiError> {
        let mut url = self.path(&["client"])?;
        match url.scheme() {
            "https" => url
                .set_scheme("wss")
                .map_err(|_| SlingshotApiError::Url("invalid websocket URL scheme".to_string()))?,
            "http" => url
                .set_scheme("ws")
                .map_err(|_| SlingshotApiError::Url("invalid websocket URL scheme".to_string()))?,
            scheme => {
                return Err(SlingshotApiError::Url(format!(
                    "unsupported websocket base scheme {scheme}"
                )));
            }
        }
        let mut request = url
            .as_str()
            .into_client_request()
            .map_err(|error| SlingshotApiError::Url(error.to_string()))?;
        let headers = request.headers_mut();
        for (name, value) in self.headers(resume_cursor, true)? {
            if let Some(name) = name {
                headers.insert(name, value);
            }
        }
        let has_session_token = if self.requires_client_session_token() {
            let session_token = self
                .client_session_token()
                .ok_or(SlingshotApiError::MissingClientSessionToken)?;
            headers.insert(
                HeaderName::from_static("x-codex-client-session-token"),
                HeaderValue::from_str(&format!("Bearer {session_token}"))?,
            );
            true
        } else {
            false
        };
        info!(
            target: "codex_slingshot",
            url = %url,
            has_resume_cursor = resume_cursor.is_some(),
            has_client_id = self.client_id().is_some(),
            has_account_id = non_empty(self.cfg.account_id.as_deref()).is_some(),
            has_session_token,
            "slingshot websocket request built"
        );
        Ok(request)
    }

    fn path(&self, parts: &[&str]) -> Result<Url, SlingshotApiError> {
        let mut url = self.cfg.base_url.clone();
        {
            let mut segments = url
                .path_segments_mut()
                .map_err(|_| SlingshotApiError::Url("base URL cannot be a base".to_string()))?;
            segments.pop_if_empty();
            match self.route {
                SlingshotRoute::Codex => {
                    segments.extend(["codex", "remote", "control"]);
                }
                SlingshotRoute::Wham => {
                    segments.extend(["wham", "remote", "control"]);
                }
            }
            segments.extend(parts.iter().copied());
        }
        Ok(url)
    }

    fn expected_target(&self, path: &str) -> Result<(String, String), SlingshotApiError> {
        let parts = path
            .trim_start_matches('/')
            .split('/')
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>();
        let url = self.path(&parts)?;
        Ok((url.origin().unicode_serialization(), url.path().to_string()))
    }

    fn headers(
        &self,
        subscribe_cursor: Option<&str>,
        streaming: bool,
    ) -> Result<HeaderMap, SlingshotApiError> {
        let mut headers = HeaderMap::new();
        let auth = format!("Bearer {}", self.cfg.auth_token.trim());
        headers.insert(AUTHORIZATION, HeaderValue::from_str(&auth)?);
        headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        headers.insert(ACCEPT_LANGUAGE, HeaderValue::from_static("en-US"));
        headers.insert(
            ACCEPT,
            HeaderValue::from_static(if streaming {
                "application/json, application/x-ndjson, text/event-stream"
            } else {
                "application/json"
            }),
        );
        headers.insert(USER_AGENT, HeaderValue::from_str(&self.cfg.user_agent)?);
        if matches!(self.route, SlingshotRoute::Codex) {
            headers.insert(
                HeaderName::from_static("x-codex-protocol-version"),
                HeaderValue::from_static(REMOTE_CONTROL_PROTOCOL_VERSION),
            );
        }
        if let Some(originator) = non_empty(self.cfg.originator.as_deref()) {
            headers.insert("originator", HeaderValue::from_str(originator)?);
        }
        if let Some(account_id) = non_empty(self.cfg.account_id.as_deref()) {
            headers.insert(
                HeaderName::from_static("chatgpt-account-id"),
                HeaderValue::from_str(account_id)?,
            );
        }
        if let Some(client_id) = self.client_id() {
            headers.insert("x-codex-client-id", HeaderValue::from_str(&client_id)?);
        }
        if let Some(cursor) = subscribe_cursor {
            headers.insert("x-codex-subscribe-cursor", HeaderValue::from_str(cursor)?);
        }
        Ok(headers)
    }
}

fn non_empty(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

fn normalize_base_url(mut url: Url) -> Url {
    let path = url.path().trim_matches('/');
    let host = url.host_str().unwrap_or_default();
    if path.is_empty() && matches!(host, "chatgpt.com" | "ios.chat.openai.com") {
        url.set_path("backend-api");
    }
    url
}

#[derive(Deserialize)]
#[serde(untagged)]
enum EnvironmentsResponse {
    Direct(Vec<SlingshotEnvironment>),
    Data {
        data: Vec<SlingshotEnvironment>,
    },
    Items {
        items: Vec<SlingshotEnvironment>,
    },
    Environments {
        environments: Vec<SlingshotEnvironment>,
    },
}

impl EnvironmentsResponse {
    fn into_vec(self) -> Vec<SlingshotEnvironment> {
        match self {
            Self::Direct(environments)
            | Self::Data { data: environments }
            | Self::Items {
                items: environments,
            }
            | Self::Environments { environments } => environments,
        }
    }
}

async fn ensure_success(
    response: reqwest::Response,
    context: &'static str,
) -> Result<reqwest::Response, SlingshotApiError> {
    let status = response.status();
    if status.is_success() {
        info!(target: "codex_slingshot", %context, %status, "slingshot http response ok");
        return Ok(response);
    }
    let body = response
        .bytes()
        .await
        .map(|bytes| preview_body(&bytes))
        .unwrap_or_else(|error| format!("<failed to read error body: {error}>"));
    if body
        .contains("Remote-control clients must use /client/enroll/start and /client/enroll/finish")
    {
        return Err(SlingshotApiError::ClientEnrollmentRequiresFinish);
    }
    warn!(
        target: "codex_slingshot",
        %context,
        %status,
        body = %sanitize_json_text(&body),
        "slingshot http response failed"
    );
    Err(SlingshotApiError::Status {
        context,
        status,
        body,
    })
}

async fn decode_json_response<T>(
    response: reqwest::Response,
    context: &'static str,
) -> Result<T, SlingshotApiError>
where
    T: DeserializeOwned,
{
    let status = response.status();
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("<missing>")
        .to_string();
    let bytes = response.bytes().await?;
    info!(
        target: "codex_slingshot",
        %context,
        %status,
        %content_type,
        body = %sanitize_json_bytes(&bytes),
        "slingshot http response body"
    );
    serde_json::from_slice(&bytes).map_err(|source| SlingshotApiError::Decode {
        context,
        status,
        content_type,
        body: preview_body(&bytes),
        source,
    })
}

fn preview_body(bytes: &[u8]) -> String {
    const LIMIT: usize = 500;
    let text = String::from_utf8_lossy(bytes);
    let mut preview: String = text.chars().take(LIMIT).collect();
    if text.chars().count() > LIMIT {
        preview.push_str("...");
    }
    preview
}

fn log_http_request(method: &str, url: &Url, context: &'static str, body: Option<&str>) {
    match body {
        Some(body) => info!(
            target: "codex_slingshot",
            %context,
            %method,
            url = %url,
            body = %body,
            "slingshot http request"
        ),
        None => info!(
            target: "codex_slingshot",
            %context,
            %method,
            url = %url,
            "slingshot http request"
        ),
    }
}

pub(crate) fn sanitize_json_bytes(bytes: &[u8]) -> String {
    match serde_json::from_slice::<serde_json::Value>(bytes) {
        Ok(value) => truncate_text(&sanitize_json_value(&value)),
        Err(_) => preview_body(bytes),
    }
}

pub(crate) fn sanitize_json_text(text: &str) -> String {
    match serde_json::from_str::<serde_json::Value>(text) {
        Ok(value) => truncate_text(&sanitize_json_value(&value)),
        Err(_) => truncate_text(text),
    }
}

pub(crate) fn sanitize_json_value(value: &serde_json::Value) -> String {
    let sanitized = sanitize_value(value.clone());
    serde_json::to_string(&sanitized).unwrap_or_else(|_| "<failed to render json>".to_string())
}

fn sanitize_value(value: serde_json::Value) -> serde_json::Value {
    match value {
        serde_json::Value::Object(map) => serde_json::Value::Object(
            map.into_iter()
                .map(|(key, value)| {
                    let sanitized = if is_sensitive_json_key(&key) {
                        serde_json::Value::String(redacted_value_summary(&value))
                    } else {
                        sanitize_value(value)
                    };
                    (key, sanitized)
                })
                .collect(),
        ),
        serde_json::Value::Array(values) => {
            serde_json::Value::Array(values.into_iter().map(sanitize_value).collect())
        }
        other => other,
    }
}

fn is_sensitive_json_key(key: &str) -> bool {
    let normalized = key.replace(['-', '_'], "").to_ascii_lowercase();
    normalized.contains("token")
        || normalized.contains("authorization")
        || normalized.contains("privatekey")
        || normalized.contains("signature")
        || normalized.contains("signedpayload")
        || normalized.contains("publickeyspkiderbase64")
}

fn redacted_value_summary(value: &serde_json::Value) -> String {
    let len = match value {
        serde_json::Value::String(value) => value.len(),
        serde_json::Value::Array(value) => value.len(),
        serde_json::Value::Object(value) => value.len(),
        _ => 0,
    };
    format!("<redacted len={len}>")
}

fn truncate_text(text: &str) -> String {
    const LIMIT: usize = 500;
    let mut preview: String = text.chars().take(LIMIT).collect();
    if text.chars().count() > LIMIT {
        preview.push_str("...");
    }
    preview
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_config() -> SlingshotConfig {
        SlingshotConfig {
            base_url: Url::parse("https://chatgpt.com/backend-api").unwrap(),
            auth_token: "token".to_string(),
            user_agent: "Litter test".to_string(),
            account_id: Some("account".to_string()),
            originator: Some("Codex Desktop".to_string()),
            client_id: Some("cli_test".to_string()),
        }
    }

    #[test]
    fn wham_route_uses_desktop_compatible_paths_without_session_token() {
        let api = SlingshotApi::new_wham(test_config());

        let enroll_url = api.path(&["client", "enroll"]).unwrap();
        assert_eq!(
            enroll_url.as_str(),
            "https://chatgpt.com/backend-api/wham/remote/control/client/enroll"
        );

        let request = api.websocket_request(None).unwrap();
        assert_eq!(
            request.uri().to_string(),
            "wss://chatgpt.com/backend-api/wham/remote/control/client"
        );
        assert!(
            !request
                .headers()
                .contains_key("x-codex-client-session-token")
        );
        assert!(!request.headers().contains_key("x-codex-protocol-version"));
    }

    #[test]
    fn codex_route_uses_device_key_paths_and_requires_session_token() {
        let api = SlingshotApi::new(test_config());

        let enroll_url = api.path(&["client", "enroll", "start"]).unwrap();
        assert_eq!(
            enroll_url.as_str(),
            "https://chatgpt.com/backend-api/codex/remote/control/client/enroll/start"
        );
        assert!(matches!(
            api.websocket_request(None),
            Err(SlingshotApiError::MissingClientSessionToken)
        ));
    }

    #[test]
    fn codex_route_uses_refresh_paths() {
        let api = SlingshotApi::new(test_config());

        let refresh_start_url = api.path(&["client", "refresh", "start"]).unwrap();
        assert_eq!(
            refresh_start_url.as_str(),
            "https://chatgpt.com/backend-api/codex/remote/control/client/refresh/start"
        );

        let (target_origin, target_path) = api.expected_target("client/refresh/finish").unwrap();
        assert_eq!(target_origin, "https://chatgpt.com");
        assert_eq!(
            target_path,
            "/backend-api/codex/remote/control/client/refresh/finish"
        );
    }
}
