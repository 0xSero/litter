use serde::{Deserialize, Serialize};

use crate::device_key::DeviceKeyEnrollment;
use crate::types::ClientEnrollmentTokenResponse;

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct SlingshotControllerSession {
    pub client_id: String,
    pub account_user_id: String,
    pub remote_control_token: String,
    pub expires_at: String,
    pub scopes: Vec<String>,
    pub device_key: DeviceKeyEnrollment,
}

impl SlingshotControllerSession {
    pub fn from_finish(
        device_key: DeviceKeyEnrollment,
        finish: ClientEnrollmentTokenResponse,
    ) -> Self {
        Self {
            client_id: finish.client_id,
            account_user_id: finish.account_user_id,
            remote_control_token: finish.remote_control_token,
            expires_at: finish.expires_at,
            scopes: finish.scopes,
            device_key,
        }
    }
}
