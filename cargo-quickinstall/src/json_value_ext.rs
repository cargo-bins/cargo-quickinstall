use std::fmt;
use tinyjson::JsonValue;

pub struct JsonExtError(String);

impl fmt::Display for JsonExtError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl fmt::Debug for JsonExtError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for JsonExtError {}

impl JsonExtError {
    fn unexpected(value: &JsonValue, expected: &str) -> Self {
        JsonExtError(format!(
            "Expecting {expected}, but found {}",
            value.get_value_type()
        ))
    }
}

pub trait JsonValueExt {
    fn extract_from_value(self, key: impl JsonKey) -> Result<JsonValue, JsonExtError>;

    fn try_into_string(self) -> Result<String, JsonExtError>;

    fn get_value_type(&self) -> &'static str;
}

impl JsonValueExt for JsonValue {
    fn extract_from_value(self, key: impl JsonKey) -> Result<JsonValue, JsonExtError> {
        key.extract_from_value(self)
    }

    fn try_into_string(self) -> Result<String, JsonExtError> {
        match self {
            JsonValue::String(s) => Ok(s),
            value => Err(JsonExtError::unexpected(&value, "String")),
        }
    }

    fn get_value_type(&self) -> &'static str {
        match self {
            JsonValue::Number(..) => "Number",
            JsonValue::Boolean(..) => "Boolean",
            JsonValue::String(..) => "String",
            JsonValue::Null => "Null",
            JsonValue::Array(..) => "Array",
            JsonValue::Object(..) => "Object",
        }
    }
}

pub trait JsonKey {
    fn extract_from_value(&self, value: JsonValue) -> Result<JsonValue, JsonExtError>;
}

impl JsonKey for usize {
    fn extract_from_value(&self, value: JsonValue) -> Result<JsonValue, JsonExtError> {
        let index = *self;

        match value {
            JsonValue::Array(mut values) => {
                let len = values.len();

                if index < len {
                    Ok(values.swap_remove(index))
                } else {
                    Err(JsonExtError(format!(
                        "Index {index} is too large for array of len {len}",
                    )))
                }
            }

            value => Err(JsonExtError::unexpected(&value, "Array")),
        }
    }
}

impl JsonKey for &str {
    fn extract_from_value(&self, value: JsonValue) -> Result<JsonValue, JsonExtError> {
        let key = *self;

        match value {
            JsonValue::Object(mut map) => map
                .remove(key)
                .ok_or_else(|| JsonExtError(format!("Key {key} not found in object"))),

            value => Err(JsonExtError::unexpected(&value, "Object")),
        }
    }
}
