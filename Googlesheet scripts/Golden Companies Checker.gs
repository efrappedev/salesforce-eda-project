/**
 * GOLDEN COMPANIES CHECKER — Script standalone
 *
 * Compara "Salesforce Sembeq Prodon" (filas a importar) contra
 * "Salesforce Eglises" (fuente de verdad = ya existe en Salesforce)
 * y escribe el resultado SOLO en una hoja nueva "Golden Companies".
 * Nunca modifica las hojas originales.
 */

var GC_CONFIG = {
  IMPORT_SHEET_NAME: 'Salesforce Sembeq Prodon',
  SOURCE_SHEET_NAME: 'Salesforce Eglises',
  OUTPUT_SHEET_NAME: 'Golden Companies',

  IMPORT_HEADERS: {
    prodonId: 'Account: ID Prodon',
    name: 'Account: Account Name',
    street: 'Account: Billing Street',
    postal: 'Account: Billing Zip/Postal Code',
    city: 'Account: Billing City',
    province: 'Account: Billing State/Province',
    country: 'Account: Billing Country'
  },

  SOURCE_HEADERS: {
    sfId: 'Id',
    prodonId: 'ID_Prodon__c',
    name: 'Name',
    street: 'BillingStreet',
    city: 'BillingCity',
    province: 'BillingState',
    postal: 'BillingPostalCode',
    country: 'BillingCountry'
  }
};

function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu('Golden Companies')
    .addItem('Run Check', 'runGoldenCompaniesCheck')
    .addToUi();
}

function runGoldenCompaniesCheck() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();

  var importSheet = ss.getSheetByName(GC_CONFIG.IMPORT_SHEET_NAME);
  if (!importSheet) throw new Error('No se encontró la hoja: ' + GC_CONFIG.IMPORT_SHEET_NAME);

  var sourceSheet = ss.getSheetByName(GC_CONFIG.SOURCE_SHEET_NAME);
  if (!sourceSheet) throw new Error('No se encontró la hoja: ' + GC_CONFIG.SOURCE_SHEET_NAME);

  var importData = importSheet.getDataRange().getDisplayValues();
  var sourceData = sourceSheet.getDataRange().getDisplayValues();

  var importCols = gcMapHeaders_(importData[0], GC_CONFIG.IMPORT_HEADERS, GC_CONFIG.IMPORT_SHEET_NAME);
  var sourceCols = gcMapHeaders_(sourceData[0], GC_CONFIG.SOURCE_HEADERS, GC_CONFIG.SOURCE_SHEET_NAME);

  var sourceRecords = gcBuildRecords_(sourceData, sourceCols, true);
  var importRecords = gcBuildRecords_(importData, importCols, false);

  var outHeader = [
    'Semáforo', 'Acción', 'Motivo',
    'Import Row', 'Import ID Prodon', 'Import Name', 'Import Address',
    'Existing Salesforce Id', 'Existing ID Prodon', 'Existing Name', 'Existing Address'
  ];

  var rows = [outHeader];
  var backgrounds = [new Array(outHeader.length).fill('#ffffff')];

  var stats = { actualizar: 0, revisar: 0, importar: 0 };

  importRecords.forEach(function(imp) {
    var best = gcFindBestMatch_(imp, sourceRecords);
    var decision = gcDecide_(best);
    stats[decision.statKey]++;

    var sf = best ? best.record : null;

    rows.push([
      decision.emoji,
      decision.action,
      decision.reason,
      imp.sheetRow,
      imp.prodonId,
      imp.name,
      gcFormatAddress_(imp),
      sf ? sf.sfId : '',
      sf ? sf.prodonId : '',
      sf ? sf.name : '',
      sf ? gcFormatAddress_(sf) : ''
    ]);
    backgrounds.push(new Array(outHeader.length).fill(decision.color));
  });

  gcWriteOutputSheet_(ss, rows, backgrounds);

  SpreadsheetApp.getUi().alert(
    'Golden Companies Check completo\n\n' +
    '🟢 Actualizar (ya existe): ' + stats.actualizar + '\n' +
    '🟡 Revisar manualmente: ' + stats.revisar + '\n' +
    '⚪ Importar (nuevo): ' + stats.importar + '\n\n' +
    'Total filas procesadas: ' + importRecords.length
  );
}

function gcMapHeaders_(headerRow, map, sheetLabel) {
  var cols = {};
  Object.keys(map).forEach(function(key) {
    var headerName = map[key];
    var idx = headerRow.indexOf(headerName);
    if (idx === -1) {
      throw new Error('No se encontró la columna "' + headerName + '" en la hoja "' + sheetLabel + '". Revisa que el encabezado exista exactamente así.');
    }
    cols[key] = idx;
  });
  return cols;
}

function gcBuildRecords_(data, cols, isSource) {
  var records = [];
  for (var i = 1; i < data.length; i++) {
    var row = data[i];
    var name = (row[cols.name] || '').trim();
    if (!name) continue;

    var record = {
      sheetRow: i + 1,
      sfId: isSource ? (row[cols.sfId] || '').trim() : '',
      prodonId: gcCleanId_(row[cols.prodonId]),
      name: name,
      street: row[cols.street] || '',
      city: row[cols.city] || '',
      province: row[cols.province] || '',
      postal: row[cols.postal] || '',
      country: row[cols.country] || ''
    };
    records.push(gcDecorate_(record));
  }
  return records;
}

function gcDecorate_(r) {
  r.postalKey = gcNormalizePostal_(r.postal);
  r.cityKey = gcNormalizeText_(r.city);
  r.nameTokens = gcStrongNameTokens_(r.name, r.city);
  var addrBase = gcExtractAddressBase_(r.street);
  r.addressBaseKey = addrBase.key;
  r.addressGroupKey = addrBase.key && r.cityKey ? (addrBase.key + '|' + r.cityKey) : addrBase.key;
  r.civic = addrBase.civic;
  return r;
}

function gcFindBestMatch_(imp, sourceRecords) {
  var best = null;
  for (var i = 0; i < sourceRecords.length; i++) {
    var sf = sourceRecords[i];
    var candidate = gcScorePair_(imp, sf);
    if (candidate.tier > 0 && (!best || candidate.tier > best.tier)) {
      best = candidate;
      best.record = sf;
    }
  }
  return best;
}

function gcScorePair_(imp, sf) {
  var idMatch = !!(imp.prodonId && sf.prodonId && imp.prodonId === sf.prodonId);
  var addressMatch =
    (imp.addressGroupKey && sf.addressGroupKey && imp.addressGroupKey === sf.addressGroupKey) ||
    (imp.postalKey && sf.postalKey && imp.cityKey && sf.cityKey && imp.postalKey === sf.postalKey && imp.cityKey === sf.cityKey) ||
    (imp.civic && sf.civic && imp.cityKey && sf.cityKey && imp.civic === sf.civic && imp.cityKey === sf.cityKey);
  var nameMatch = gcTokensOverlap_(imp.nameTokens, sf.nameTokens);

  if (idMatch) return { tier: 2, reason: 'Mismo ID Prodon (' + imp.prodonId + ')' };
  if (addressMatch && nameMatch) return { tier: 2, reason: 'Misma dirección + nombre compatible' };
  if (nameMatch) return { tier: 1, reason: 'Nombre parecido, dirección distinta' };
  if (addressMatch) return { tier: 1, reason: 'Misma dirección, nombre no confirma' };
  return { tier: 0, reason: '' };
}

function gcTokensOverlap_(a, b) {
  if (!a || !b || !a.length || !b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (b.indexOf(a[i]) !== -1) return true;
  }
  return false;
}

function gcDecide_(best) {
  var tier = best ? best.tier : 0;
  if (tier === 2) {
    return { emoji: '🟢', action: 'ACTUALIZAR (ya existe)', reason: best.reason, color: '#d9ead3', statKey: 'actualizar' };
  }
  if (tier === 1) {
    return { emoji: '🟡', action: 'REVISAR', reason: best.reason, color: '#fff2cc', statKey: 'revisar' };
  }
  return { emoji: '⚪', action: 'IMPORTAR', reason: '', color: '#ffffff', statKey: 'importar' };
}

function gcFormatAddress_(r) {
  return [r.street, r.city, r.province, r.postal, r.country]
    .map(function(v) { return (v || '').toString().trim(); })
    .filter(function(v) { return !!v; })
    .join(', ');
}

function gcWriteOutputSheet_(ss, rows, backgrounds) {
  var existing = ss.getSheetByName(GC_CONFIG.OUTPUT_SHEET_NAME);
  if (existing) ss.deleteSheet(existing);

  var sheet = ss.insertSheet(GC_CONFIG.OUTPUT_SHEET_NAME);
  var numRows = rows.length;
  var numCols = rows[0].length;

  sheet.getRange(1, 1, numRows, numCols).setValues(rows);
  sheet.getRange(1, 1, numRows, numCols).setBackgrounds(backgrounds);

  sheet.getRange(1, 1, 1, numCols).setFontWeight('bold');
  sheet.setFrozenRows(1);

  for (var c = 1; c <= numCols; c++) {
    sheet.autoResizeColumn(c);
  }

  ss.setActiveSheet(sheet);
}

// ---------- Helpers de texto / normalización ----------

function gcNormalizeText_(value) {
  return (value || '')
    .toString()
    .trim()
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[’']/g, ' ')
    .replace(/[^a-z0-9\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function gcNormalizePostal_(value) {
  return (value || '').toString().trim().toUpperCase().replace(/\s+/g, '');
}

function gcCleanId_(value) {
  return (value || '').toString().trim().replace(/\s+/g, '');
}

function gcIsNumber_(value) {
  return /^\d+$/.test((value || '').toString());
}

function gcTitleCase_(text) {
  return (text || '')
    .toString()
    .split(/\s+/)
    .filter(Boolean)
    .map(function(w) { return w.charAt(0).toUpperCase() + w.slice(1); })
    .join(' ');
}

function gcStrongNameTokens_(name, city) {
  var stop = {
    eglise: true, church: true, paroisse: true, parish: true,
    baptist: true, baptiste: true, evangelique: true, evangelical: true,
    fellowship: true, ministere: true, ministry: true, ministries: true,
    centre: true, center: true, communaute: true, community: true,
    association: true, organisation: true, organization: true, corporation: true,
    compagnie: true, company: true, inc: true, ltee: true, ltd: true, corp: true,
    fondation: true, foundation: true, projet: true, mission: true, maison: true,
    de: true, du: true, des: true, la: true, le: true, les: true, l: true, d: true,
    the: true, and: true, et: true, saint: true, sainte: true, st: true, ste: true
  };

  gcNormalizeText_(city).split(/\s+/).forEach(function(t) {
    if (t) stop[t] = true;
  });

  var tokens = gcNormalizeText_(name).split(/\s+/).filter(function(t) {
    return t.length >= 4 && !stop[t];
  });

  var unique = {};
  var out = [];
  tokens.forEach(function(t) {
    if (!unique[t]) { unique[t] = true; out.push(t); }
  });

  return out;
}

function gcExtractAddressBase_(street) {
  var text = gcNormalizeText_(street);
  if (!text) return { key: '', civic: '', display: '' };

  text = text
    .replace(/\b(canada|quebec|qc|ontario|on)\b/g, ' ')
    .replace(/\b(suite|bureau|bur|local|unit|unite|apt|app|appartement|porte|floor|etage|niveau)\b.*$/g, ' ')
    .replace(/[,;].*$/g, ' ')
    .replace(/-/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  text = text
    .replace(/\bboul\.?\b/g, 'boulevard')
    .replace(/\bblvd\.?\b/g, 'boulevard')
    .replace(/\bav\.?\b/g, 'avenue')
    .replace(/\bave\.?\b/g, 'avenue')
    .replace(/\brd\.?\b/g, 'road')
    .replace(/\brte\.?\b/g, 'route')
    .replace(/\bch\.?\b/g, 'chemin')
    .replace(/\s+/g, ' ')
    .trim();

  var tokens = text.split(/\s+/).filter(Boolean);
  if (!tokens.length) return { key: '', civic: '', display: '' };

  var civicIndex = -1;
  if (tokens.length >= 2 && gcIsNumber_(tokens[0]) && gcIsNumber_(tokens[1])) {
    civicIndex = 1;
  } else {
    for (var i = 0; i < tokens.length; i++) {
      if (gcIsNumber_(tokens[i])) { civicIndex = i; break; }
    }
  }

  if (civicIndex === -1) {
    return { key: tokens.join(' '), civic: '', display: gcTitleCase_(tokens.join(' ')) };
  }

  var civic = tokens[civicIndex];
  var streetTokens = tokens.slice(civicIndex + 1);

  var streetTypeWords = {
    rue: true, boulevard: true, avenue: true, road: true, chemin: true,
    route: true, drive: true, dr: true, place: true, pl: true,
    court: true, ct: true, crescent: true, terrace: true, terrasse: true
  };

  streetTokens = streetTokens.filter(function(t) { return !streetTypeWords[t]; });

  var streetName = streetTokens.join(' ').trim();

  if (!streetName) {
    return { key: civic, civic: civic, display: civic };
  }

  return {
    key: civic + '|' + streetName,
    civic: civic,
    display: civic + ' ' + gcTitleCase_(streetName)
  };
}
