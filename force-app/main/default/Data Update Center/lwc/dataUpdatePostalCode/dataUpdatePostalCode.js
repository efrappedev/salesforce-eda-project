// Canadian postal codes are shown and stored "A1A 1A1"; every other country's code is kept as
// typed. Mirrors DataUpdateFormConfigService.formatPostalCode() in Apex — keep both in sync.

const CANADA_COUNTRY_VALUES = new Set(['CA', 'CAN', 'CANADA']);
const CANADIAN_POSTAL_SHAPE = /^[A-Z][0-9][A-Z][0-9][A-Z][0-9]$/;
// A started-but-broken Canadian code (A1B, A1B2, A1B2C, A1B2C33...). Other countries' codes
// (UK W1A 1AA, Irish D02 AF30, numeric codes) don't fit it, so they're never flagged.
const CANADIAN_POSTAL_ATTEMPT = /^[A-Z][0-9][A-Z]([0-9]([A-Z][0-9]*)?)?$/;

export function isPostalCodeField(fieldApiName) {
    return /postalcode$/i.test(fieldApiName || '');
}

// PersonMailingPostalCode → PersonMailingCountry (same address, standard naming).
export function countryFieldFor(postalFieldApiName) {
    return postalFieldApiName.replace(/PostalCode$/i, 'Country');
}

export function isCountryField(fieldApiName) {
    return /country$/i.test(fieldApiName || '');
}

export function postalFieldFor(countryFieldApiName) {
    return countryFieldApiName.replace(/Country$/i, 'PostalCode');
}

function isCanada(country) {
    return CANADA_COUNTRY_VALUES.has((country || '').trim().toUpperCase());
}

/**
 * Known Canadian country → "A1A 1A1" (letters upper-cased, formatted as the user types; extra
 * characters are kept so isInvalidPostalCode() can flag them instead of silently cutting them).
 * Known other country → unchanged. No country → formatted only once the value has the Canadian
 * letter/digit shape, which no other country's postal code uses.
 */
export function formatPostalCode(value, country) {
    if (!value) return value;
    const countryKnown = !!(country && country.trim());
    if (countryKnown && !isCanada(country)) return value;

    const compact = value.replace(/[^A-Za-z0-9]/g, '').toUpperCase();
    if (!countryKnown) {
        return CANADIAN_POSTAL_SHAPE.test(compact) ? `${compact.slice(0, 3)} ${compact.slice(3)}` : value;
    }
    return compact.length > 3 ? `${compact.slice(0, 3)} ${compact.slice(3)}` : compact;
}

/**
 * True when a Canadian postal code is malformed: country known as Canada and the value isn't
 * exactly A1A1A1, or no country and the value is a broken Canadian-shaped attempt.
 */
export function isInvalidPostalCode(value, country) {
    if (!value) return false;
    const countryKnown = !!(country && country.trim());
    if (countryKnown && !isCanada(country)) return false;

    const compact = value.replace(/[^A-Za-z0-9]/g, '').toUpperCase();
    if (CANADIAN_POSTAL_SHAPE.test(compact)) return false;
    return countryKnown || CANADIAN_POSTAL_ATTEMPT.test(compact);
}
