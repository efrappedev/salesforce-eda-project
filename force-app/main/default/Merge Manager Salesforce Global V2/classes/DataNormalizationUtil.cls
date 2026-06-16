/**
 * DataNormalizationUtil.cls
 * Stateless utility for normalizing field values used in duplicate detection.
 * All methods are deterministic and side-effect-free — safe to call from any context.
 */
public without sharing class DataNormalizationUtil {

    private static final Integer PHONE_MIN_DIGITS              = 7;
    private static final Integer PHONE_NA_LENGTH_WITH_COUNTRY  = 11;

    // Accent map: uppercase keys so we only upper() the input once
    private static final Map<String,String> ACCENT_MAP = new Map<String,String>{
        'À'=>'A','Á'=>'A','Â'=>'A','Ã'=>'A','Ä'=>'A',
        'È'=>'E','É'=>'E','Ê'=>'E','Ë'=>'E',
        'Ì'=>'I','Í'=>'I','Î'=>'I','Ï'=>'I',
        'Ò'=>'O','Ó'=>'O','Ô'=>'O','Õ'=>'O','Ö'=>'O',
        'Ù'=>'U','Ú'=>'U','Û'=>'U','Ü'=>'U',
        'Ñ'=>'N','Ç'=>'C','Ý'=>'Y','Ÿ'=>'Y'
    };

    // ─── Public normalizers ───────────────────────────────────────────────────

    public static String normalizeEmail(String email) {
        if (String.isBlank(email)) return null;
        String result = email.trim().toLowerCase();
        return result.length() > 0 ? result : null;
    }

    public static String normalizePhone(String phone) {
        if (String.isBlank(phone)) return null;
        String digits = phone.replaceAll('[^0-9]', '');
        // Strip North American country code prefix
        if (digits.length() == PHONE_NA_LENGTH_WITH_COUNTRY && digits.startsWith('1')) {
            digits = digits.substring(1);
        }
        return (digits.length() >= PHONE_MIN_DIGITS) ? digits : null;
    }

    public static String normalizeName(String name) {
        if (String.isBlank(name)) return null;
        String result = name.trim().toUpperCase();
        for (String accented : ACCENT_MAP.keySet()) {
            result = result.replace(accented, ACCENT_MAP.get(accented));
        }
        while (result.contains('  ')) {
            result = result.replace('  ', ' ');
        }
        result = result.trim();
        return result.length() > 0 ? result : null;
    }

    /**
     * Builds a canonical match key in the format: OBJ|TYPE|NORMALIZED_VALUE
     * Example: "Contact|Email|john@example.com"
     * Returns null if the value normalizes to blank (caller should skip it).
     */
    public static String buildMatchKey(String objectType, String matchType, String rawValue) {
        String normalized;
        switch on matchType {
            when 'Email' { normalized = normalizeEmail(rawValue); }
            when 'Phone' { normalized = normalizePhone(rawValue); }
            when 'Name'  { normalized = normalizeName(rawValue);  }
            when else    { normalized = rawValue?.trim();          }
        }
        if (String.isBlank(normalized)) return null;
        return objectType + '|' + matchType + '|' + normalized;
    }

    /**
     * Derives a confidence level.
     * Email is always High (globally unique identifiers).
     * Phone requires at least 2 matching fields for Medium.
     */
    public static String inferConfidence(String matchType, Integer matchingFieldCount) {
        if (matchType == 'Email')                  return 'High';
        if (matchType == 'Phone' && matchingFieldCount >= 2) return 'High';
        if (matchType == 'Phone')                  return 'Medium';
        return 'Low';
    }
}
