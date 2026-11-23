import requests
from bs4 import BeautifulSoup
import re
import csv
import json
import os
import sys
import time
import random
import unicodedata
from urllib.parse import urljoin, urlsplit, urlunsplit
from datetime import date, datetime, timedelta


# --- CONFIGURATION ---
SCRAPERAPI_KEY = os.environ.get("SCRAPERAPI_KEY", "")

# ScraperAPI answers 500 when its own internal retries time out, and 429 when
# the concurrency limit is hit. Neither is billed and both are worth retrying.
# 401 (bad key) / 403 (out of credits) / 404 (dead page) are permanent.
RETRYABLE_STATUS = (408, 429, 500, 502, 503, 504)


def get_html_with_scraperapi(ad_url, attempts=3):
    """Fetches HTML content using ScraperAPI to bypass blocks.

    Returns (html, error) - exactly one of the two is set, so the caller can
    tell "page had no data" apart from "page was never fetched".
    """
    payload = {'api_key': SCRAPERAPI_KEY, 'url': ad_url}
    error = "no response"

    for attempt in range(1, attempts + 1):
        try:
            # We use the ScraperAPI URL as the base
            response = requests.get('https://api.scraperapi.com/', params=payload, timeout=90)
            if response.status_code == 200:
                return response.text, None

            error = f"HTTP {response.status_code}"
            retryable = response.status_code in RETRYABLE_STATUS
        except Exception as e:
            error = f"{type(e).__name__}: {e}"
            retryable = True

        print(f"❌ Attempt {attempt}/{attempts} failed for {ad_url}. Status: {error}")

        if not retryable or attempt == attempts:
            break
        time.sleep(5 * attempt)   # back off before trying again

    print(f"❌ Giving up on {ad_url}. Status: {error}")
    return None, error


def fold(text):
    """Lower-case without accents: "Máj" -> "maj"."""
    decomposed = unicodedata.normalize("NFD", str(text or ""))
    return "".join(c for c in decomposed if not unicodedata.combining(c)).lower()


MONTHS = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "maj": 5, "jun": 6,
          "jul": 7, "aug": 8, "sep": 9, "okt": 10, "nov": 11, "dec": 12}


def parse_season_day(text, year):
    """"1. jan", "1.1." or "25. 12. 2026" as a date; None when unreadable.

    Seasons are quoted without a year ("1. jan - 31. dec"), so they mean the
    year the scrape runs in - hardcoding one silently ages the whole sheet.
    """
    t = fold(text)
    match = re.search(r"(\d{1,2})\s*[./]\s*(\d{1,2})(?:\s*[./]\s*(\d{4}))?", t)
    if match:
        day, month, found_year = int(match.group(1)), int(match.group(2)), match.group(3)
    else:
        match = re.search(r"(\d{1,2})\s*\.?\s*(jan|feb|mar|apr|maj|jun|jul|aug|sep|okt|nov|dec)[a-z]*", t)
        if not match:
            return None
        day, month, found_year = int(match.group(1)), MONTHS[match.group(2)], None
    try:
        return date(int(found_year or year), month, day)
    except ValueError:
        return None


def parse_season_range(text):
    """"23. dec - 3. jan" -> (start, end) dates, the end rolled into next year.

    A season that wraps New Year has its end before its start; left as is it
    would reach Putko as an offer ending before it begins and never apply.
    """
    parts = re.split(r"\s*[-\u2013]\s*", (text or "").strip())
    if len(parts) != 2:
        return None
    start = parse_season_day(parts[0], datetime.now().year)
    end = parse_season_day(parts[1], start.year) if start else None
    if not (start and end):
        return None
    if end < start and not re.search(r"\d{4}", parts[1]):
        end = parse_season_day(parts[1], start.year + 1)
    return (start, end) if end else None


def parse_amount(text):
    """The first number in "12,50 €" / "140 €" as 12.5 / 140; None when absent.

    A bare `(\\d+)\\s*€` reads "12,50 €" as 50.
    """
    match = re.search(r"\d+(?:[.,]\d+)?", str(text or ""))
    if not match:
        return None
    number = float(match.group(0).replace(",", "."))
    return int(number) if number.is_integer() else number


def shift_year(day, years):
    try:
        return day.replace(year=day.year + years)
    except ValueError:      # 29 February
        return day.replace(year=day.year + years, day=28)


def normalize_time(value):
    """"8:00" / "14:00" -> "08:00:00". Times are written HH:MM:SS in the sheet."""
    if not value:
        return ""
    match = re.match(r"(\d{1,2}):(\d{2})(?::(\d{2}))?$", value.strip())
    if not match:
        return ""
    hour, minute, second = match.group(1), match.group(2), match.group(3) or "00"
    return f"{int(hour):02d}:{minute}:{second}"


def extract_json_array(html_content, key):
    """Pulls a JSON array out of the embedded window.clientData blob.

    A plain regex can't be used because the arrays contain nested objects and
    escaped quotes (roomText holds raw HTML), so we bracket-match instead.
    """
    for match in re.finditer(r'"%s"\s*:\s*\[' % re.escape(key), html_content):
        start = match.end() - 1
        depth = 0
        in_string = False
        escaped = False

        for i in range(start, len(html_content)):
            char = html_content[i]

            if in_string:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    in_string = False
                continue

            if char == '"':
                in_string = True
            elif char == "[":
                depth += 1
            elif char == "]":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(html_content[start:i + 1])
                    except json.JSONDecodeError:
                        break
    return None


def find_json_ld(soup, *types):
    """Returns the first application/ld+json block whose @type matches."""
    for script in soup.find_all('script', type="application/ld+json"):
        try:
            data = json.loads(script.string or "")
        except (json.JSONDecodeError, TypeError):
            continue
        if isinstance(data, list):
            data = next((d for d in data if isinstance(d, dict)), None)
        if isinstance(data, dict) and (not types or data.get("@type") in types):
            return data
    return None


NOT_FOUND = "not found"
ERROR_PREFIX = "ERROR: "

CSV_HEADERS = ["propertyUrl", "propertyName", "city", "streetAndNumber", "name",
               "phoneNumber", "email", "acreage", "arrivalFrom", "arrivalTo",
               "bathroom", "bedroom", "beds", "departureFrom", "departureTo",
               "description", "pricePerNight", "discount", "doublebed", "images",
               "kitchen", "nightMax", "nightMin", "person", "priceFriSun",
               "priceMonThus", "singlebed", "userId", "latitude", "longitude",
               "zipCode", "Country", "state", "flexiblePrice", "WCs", "LivingRoom",
               "reviewsHeader", "reviewsId", "rating", "reviews", "units"]

# The "units" column holds a JSON list in Putko's own unit shape (see
# backend/models/Accommodation.js `unitSchema`), so importHost.js can store it
# on the listing as-is. A single-unit property writes "[]" and imports exactly
# as it always has.
NO_UNITS = "[]"

# hauzi publishes the country as an ISO code; the sheet wants the Slovak name.
COUNTRY_NAMES = {
    "SK": "Slovensko", "CZ": "Česko", "PL": "Poľsko",
    "HU": "Maďarsko", "AT": "Rakúsko", "SI": "Slovinsko", "HR": "Chorvátsko",
}

# Fallback map centre of Slovakia, used only when the page ships no geo data.
DEFAULT_LATITUDE = 48.669026
DEFAULT_LONGITUDE = 19.699024

# The area of a unit is only quoted in its modal; when it is absent the sheet
# has always carried this placeholder rather than an empty cell.
DEFAULT_ACREAGE = 100

# Sits under the owner's name in the sidebar. It is a disclaimer, not a surname,
# so it must not be glued onto the name.
OWNER_NOTES = (
    "majiteľ", "majitel", "ubytovateľ", "ubytovatel", "host", "hostitel",
    "hostiteľ", "nebýva", "nebyva", "objekt", "building",
)

# hauzi hides the end of the owner's number until a booking enquiry is sent, so
# the public page only ever offers "+421 918 466 xxx" / "+421 918 466 … zobraziť
# číslo". Two or more x/*/. in a row (or an ellipsis) is the mask; a single dot
# is left alone because some numbers are written "+421.918.466.123".
PHONE_MASK = re.compile(r"x{2,}|\*{2,}|\.{2,}|…", re.I)


def make_error_row(ad_url, message):
    """A link that could not be scraped still gets a row.

    Otherwise a failed listing silently disappears from the sheet and you
    can't tell it apart from one that was never in the input list.
    """
    row = [NOT_FOUND] * len(CSV_HEADERS)
    row[0] = ad_url
    row[1] = ERROR_PREFIX + message
    return row


def or_not_found(value):
    """Writes "not found" instead of leaving a CSV cell empty.

    A real zero is kept as 0 - "the unit has no bathroom" is a different fact
    from "the page never said".
    """
    if value is None:
        return NOT_FOUND
    if isinstance(value, (list, tuple, dict)) and not value:
        return NOT_FOUND
    if isinstance(value, str) and not value.strip():
        return NOT_FOUND
    return value


def count_rooms(text, *patterns):
    """Sums the "3x <room>" counters found in a unit's room description."""
    total = 0
    for pattern in patterns:
        for match in re.finditer(r"(\d+)\s*x\s*" + pattern, text, re.I):
            total += int(match.group(1))
    return total


# Room counters, in both the Slovak original and the English translation of the
# page. "kúpeľňa s toaletou" is an ensuite; "kúpeľňa bez toalety" is not, so the
# WC patterns must require the "s"/"with" and never match the "bez"/"without"
# variant.
BATHROOM_PATTERNS = (r"kúpeľň", r"kupeln", r"bathroom")
WC_PATTERNS = (
    r"kúpeľň\w*\s+s\s+toalet",
    r"kúpeľň\w*\s+s\s*WC",
    r"samostatn\w*\s+toalet",
    r"samostatn\w*\s*WC",
    r"bathroom with toilet",
    r"separate toilet",
)
# "kuchyňa", "kuchynka" and "kuchynský kút" all count as a kitchen. The n/ň
# alternation matters: most listings write "kuchyňa", a few "kuchynka".
KITCHEN_PATTERNS = (r"kuchy[nň]", r"kitchen(?:ette)?")
LIVING_ROOM_PATTERNS = (
    r"spoločensk\w*\s+miestnos",
    r"obývacia\s+izba",
    r"(?:common|living|social)\s+room",
)


def parse_price_table(container):
    """Reads a "Cenník" block into {seasons, first_price, min_nights}.

    Used twice: once for the listing-wide table and again for the table inside
    each unit's modal. A four-apartment villa quotes a different price per
    apartment, so units must not all inherit the listing-level price.
    """
    result = {"seasons": [], "first_price": "", "min_nights": ""}
    if not container:
        return result

    # The narrow "mobile-only" rows repeat the full table in two cells; the
    # first of them is the headline season, which is what priceFriSun uses.
    first_row = container.find("tr", class_="mobile-only")
    if first_row:
        price_cell = first_row.find("td", class_="text-right") or first_row.find_all("td")[-1:]
        price_cell = price_cell if not isinstance(price_cell, list) else (price_cell[0] if price_cell else None)
        if price_cell:
            first_price = parse_amount(price_cell.get_text(strip=True))
            if first_price:
                result["first_price"] = str(first_price)

    table = container.find("table")
    if not table:
        return result

    seen = set()
    nights = []
    for row in table.find_all("tr"):
        cols = row.find_all("td")
        if len(cols) < 6:
            continue

        # Putko cannot apply an offer without a date range and a price, so a
        # row missing either is not a season.
        span = parse_season_range(cols[1].get_text(strip=True))
        price = parse_amount(cols[5].get_text(strip=True))
        if not span or not price or price <= 0:
            continue
        start, end = span

        season_text = cols[0].get_text(strip=True)
        name = re.sub(r"\s*\d+.*$", "", season_text).strip() or season_text or "Unknown"

        min_persons_match = re.search(r"\d+", cols[2].get_text(strip=True))
        min_persons = min_persons_match.group(0) if min_persons_match else ""

        min_nights_match = re.search(r"\d+", cols[3].get_text(strip=True))
        min_nights = min_nights_match.group(0) if min_nights_match else ""
        if min_nights:
            nights.append(int(min_nights))

        accommodation_note = cols[4].get_text(strip=True)

        # Rows differing only in persons or nights are different tiers of the
        # same season, so both belong in the key.
        key = f"{name}_{start}_{end}_{price}_{min_nights}_{min_persons}"
        if key in seen:
            continue
        seen.add(key)
        result["seasons"].append({
            "name": name,
            "start": start.isoformat(),
            "end": end.isoformat(),
            "price": price,
            "min_persons": min_persons,
            "min_nights": min_nights,
            "accommodation_note": accommodation_note,
        })

    # The shortest stay any season will accept is the listing's minimum.
    if nights:
        result["min_nights"] = min(nights)

    return result


def price_for_today(seasons):
    """The nightly price of the season the scrape date falls into.

    A season that wraps New Year ("23. dec - 3. jan") ends in the next year, so
    early January is inside last year's copy of it: the dates are also checked
    shifted back a year. Where several seasons overlap today (a weekend rate on
    top of the all-year one) the cheapest wins, which is the rate the listing
    advertises as "from".
    """
    today = datetime.now().date()
    matching = []
    for season in seasons:
        start, end, price = season.get("start"), season.get("end"), season.get("price")
        if not (start and end and price):
            continue
        start, end = date.fromisoformat(start), date.fromisoformat(end)
        if start <= today <= end or shift_year(start, -1) <= today <= shift_year(end, -1):
            matching.append(price)
    return min(matching) if matching else None


def extract_int_array(html_content, key):
    """A flat number array from window.clientData ("calendarPrices": [160, ...])."""
    match = re.search(r'"%s"\s*:\s*\[([^\]]*)\]' % re.escape(key), html_content)
    return [int(n) for n in re.findall(r"-?\d+", match.group(1))] if match else []


def calendar_start_date(html_content):
    """The day index 0 of calendarPrices/calendarCache stands for.

    The arrays begin on 1 January of the year the calendar was last updated
    ("calendarUpdatedAt": "07/10/2026", day/month/year); the scrape date's year
    is the fallback. Checked against a listing whose calendar raises the price
    exactly over Easter 2026 (2-5 Apr) and Easter 2027 (25-28 Mar).
    """
    match = re.search(r'"calendarUpdatedAt"\s*:\s*"\d{1,2}/\d{1,2}/(\d{4})"', html_content)
    year = int(match.group(1)) if match else datetime.now().year
    return date(year, 1, 1)


def parse_calendar_seasons(html_content):
    """Turns the per-day calendar prices into flexiblePrice seasons.

    Many hauzi listings publish no "Cenník" table at all and only price their
    calendar day by day (160 € most of the year, 290 € over Christmas, 270 €
    over Easter...). Consecutive days with the same price become one season,
    in the same shape parse_price_table produces, so the importer handles both
    alike. Days before today are dropped; a booked day still carries its
    price, so availability is not consulted.
    """
    prices = extract_int_array(html_content, "calendarPrices")
    if not prices:
        return []

    # A listing-wide minimum stay, when the page sets one; null on most pages.
    min_stay_match = re.search(r'"minStay"\s*:\s*(\d+)', html_content)
    min_nights = min_stay_match.group(1) if min_stay_match else ""

    first_day = calendar_start_date(html_content)
    today = datetime.now().date()

    seasons = []
    run_start = None
    for index in range(len(prices) + 1):
        day = first_day + timedelta(days=index)
        price = prices[index] if index < len(prices) else None

        # Close the open run when the price changes or the array ends.
        if run_start is not None and price != prices[run_start]:
            start = first_day + timedelta(days=run_start)
            end = day - timedelta(days=1)
            seasons.append({
                "name": f"Kalendár {start.day}.{start.month}.{start.year} - "
                        f"{end.day}.{end.month}.{end.year}",
                "start": start.isoformat(),
                "end": end.isoformat(),
                "price": prices[run_start],
                "min_persons": "",
                "min_nights": min_nights,
                "accommodation_note": "",
            })
            run_start = None

        if price is None or day < today or price <= 0:
            continue
        if run_start is None:
            run_start = index

    return seasons


def parse_units(html_content, soup):
    """Returns one dict per rental unit of a multi-unit property.

    Properties like "Chata Chopok" bundle several apartments/rooms under a
    single listing. The per-unit data lives in window.clientData.rental.units;
    the visible page only renders it inside the "unit-modal-<id>" popups.
    """
    raw_units = extract_json_array(html_content, "units")
    if not isinstance(raw_units, list):
        return []

    units = []
    for raw in raw_units:
        if not isinstance(raw, dict) or not raw.get("name"):
            continue

        unit_id = raw.get("_id", "")

        # roomText is an HTML fragment ("<b>2x&nbsp;bedroom</b>: 1x double bed ...")
        room_text = raw.get("roomText", "") or ""
        room_text = BeautifulSoup(room_text, "html.parser").get_text(" ", strip=True)
        room_text = room_text.replace("\xa0", " ")
        room_text = re.sub(r"\s+", " ", room_text)

        # The JSON omits a bed/room key entirely when its count is zero, so an
        # absent key on a unit that HAS the parent object still means "0".
        capacity = raw.get("capacity")
        capacity = capacity if isinstance(capacity, dict) else {}
        bed_counts = raw.get("beds")
        bed_counts = bed_counts if isinstance(bed_counts, dict) else None

        # Without a roomText there is nothing to count, so leave them unknown.
        bathroom = WCs = kitchen = LivingRoom = ""
        if room_text:
            bathroom = count_rooms(room_text, *BATHROOM_PATTERNS)
            WCs = count_rooms(room_text, *WC_PATTERNS)
            kitchen = count_rooms(room_text, *KITCHEN_PATTERNS)
            LivingRoom = count_rooms(room_text, *LIVING_ROOM_PATTERNS)

        bedroom = raw.get("bedroomsCount")
        if not bedroom:
            bedroom = count_rooms(room_text, r"bedroom", r"spál[nň]") if room_text else ""

        # Area is only rendered in the modal ("Floor, Area: 40m2"), not in the JSON
        acreage = ""
        modal = soup.find("div", id="unit-modal-%s" % unit_id) if unit_id else None
        if modal:
            area_match = re.search(
                r"(?:Area|Plocha)\s*:?\s*(\d+)\s*m", modal.get_text(" ", strip=True), re.I
            )
            if area_match:
                acreage = area_match.group(1)

        # Prefer the <img> tags inside the modal; fall back to rebuilding the
        # CDN path from the photo ids (https://images.hauzi.com/700/<xx>/<id>.jpg)
        images = []
        if modal:
            images = [
                img["src"].strip()
                for img in modal.select(".li-photos img")
                if img.get("src")
            ]
        if not images:
            for photo in raw.get("photos") or []:
                photo_id = photo.get("_id") if isinstance(photo, dict) else photo
                if photo_id:
                    images.append(
                        "https://images.hauzi.com/700/%s/%s.jpg" % (photo_id[-2:], photo_id)
                    )

        # Each unit's modal carries its own "Cenník"; without it every
        # apartment of a villa would be written out at the same price.
        unit_prices = parse_price_table(modal.select_one("div.table-prices")) if modal else None
        unit_prices = unit_prices or {"seasons": [], "first_price": "", "min_nights": ""}

        units.append({
            "name": raw["name"],
            "person": capacity.get("total", capacity.get("regular", "")),
            "beds": capacity.get("extra", ""),            # extra beds / prístelky
            "doublebed": bed_counts.get("couple", 0) if bed_counts is not None else "",
            "singlebed": bed_counts.get("adult", 0) if bed_counts is not None else "",
            "bedroom": bedroom,
            "bathroom": bathroom,
            "WCs": WCs,
            "kitchen": kitchen,
            "LivingRoom": LivingRoom,
            "acreage": acreage or DEFAULT_ACREAGE,
            "images": images,
            "seasons": unit_prices["seasons"],
            "price": price_for_today(unit_prices["seasons"]),
            "firstPrice": unit_prices["first_price"],
            "nightMin": unit_prices["min_nights"],
        })

    return units


def as_count(value):
    """A positive whole number from a scraped cell, or None when unknown/zero."""
    try:
        number = int(float(value))
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None


def seasons_to_putko(seasons):
    """Scraped seasons as Putko seasonal offers (flexiblePricePeriodShape).

    Same rules as hauziSync/parse.js: rows sharing a name and date range are ONE
    offer with a tier each; a tier is a price for the row's minimum nights and
    minimum persons (minGuests). Only seasons with a date range and a price are
    kept, because Putko cannot apply an offer without both.
    """
    periods = {}
    for season in seasons:
        start, end, price = season.get("start"), season.get("end"), season.get("price")
        if not (start and end and price):
            continue
        period = periods.setdefault((season.get("name") or "", start, end), {
            "name": season.get("name") or "",
            "start": start,
            "end": end,
            "note": season.get("accommodation_note") or "",
            "applyDiscounts": True,
            "tiers": [],
        })
        period["tiers"].append({
            "minNights": as_count(season.get("min_nights")) or 1,
            "maxNights": None,
            "minGuests": as_count(season.get("min_persons")),
            "maxGuests": None,
            "price": price,
        })
    return list(periods.values())


def unit_to_putko(unit):
    """One scraped unit in Putko's unit shape, for the "units" column.

    A Putko unit only states what differs from its listing - anything left out
    falls back to the listing's value - so unknown values are omitted rather
    than written as 0 or "not found".
    """
    data = {"name": unit["name"]}

    for key in ("person", "bedroom", "bathroom"):
        count = as_count(unit.get(key))
        if count:
            data[key] = count

    # Putko's `beds` is the number of beds. hauzi's unit "beds" is the extra
    # beds (prístelky), so the real figure is double + single beds.
    beds = (as_count(unit.get("doublebed")) or 0) + (as_count(unit.get("singlebed")) or 0)
    if beds:
        data["beds"] = beds

    price = unit.get("price") or as_count(unit.get("firstPrice"))
    if price:
        data["pricePerNight"] = price
        # A unit's offers only apply when it has its own price (listingUnits.js).
        offers = seasons_to_putko(unit.get("seasons") or [])
        if offers:
            data["flexiblePrices"] = offers

    if unit.get("images"):
        data["images"] = unit["images"]

    return data


def parse_owner(soup):
    """Reads the host block in the detail sidebar.

    Layout is
        <div class="detail-sidebar-owner-info"> <b>NAME</b> <small>...</small>
    where the <small> is sometimes the surname ("Diana" / "Podpora") and
    sometimes the "the host does not live in the building" disclaimer, so the
    second half is only appended when it looks like a name.

    Returns (name, phone). hauzi masks the last three digits of the phone until
    a booking enquiry is submitted, so the sidebar normally holds nothing but
    "+421 903 255 xxx"; `phone` comes back empty in that case, and only carries
    a number when the page publishes a complete one.
    """
    name = ""
    phone = ""

    info = soup.select_one(".detail-sidebar-owner-info, .detail-mobile-owner-box-inner")
    if info:
        bold = info.find("b")
        if bold:
            name = bold.get_text(" ", strip=True)

        note = info.find("small")
        if note and name:
            extra = note.get_text(" ", strip=True)
            lowered = extra.lower()
            is_disclaimer = any(word in lowered for word in OWNER_NOTES)
            # A surname is one capitalised word; the disclaimer is a sentence.
            if extra and not is_disclaimer and len(extra.split()) == 1 and extra[:1].isupper():
                name = f"{name} {extra}"

    masked = soup.select_one(".detail-mobile-owner-phone")
    if masked:
        phone = masked.get_text(" ", strip=True)
    else:
        # Desktop renders the same number inside the green button, followed by
        # the "zobraziť číslo" / "display number" call to action.
        button = soup.select_one(".detail-sidebar-owner a span")
        if button:
            phone = button.get_text(" ", strip=True)

    if phone:
        phone = re.sub(r"\s+", " ", phone).strip()
        # A number whose ending is masked cannot be dialled, so it is dropped
        # rather than written to the sheet as "+421 918 466 xxx". The caller
        # then falls back to the number in the JSON blob, and to "Phone not
        # found" when the page never publishes a full one - which is the normal
        # case here, hauzi only releases it through a booking enquiry.
        if PHONE_MASK.search(phone):
            phone = ""

    return name, phone


def scrape_ad_details(ad_url):
    """Scrapes an ad page and returns a list holding its one row.

    A multi-unit property is still one row; its units ride in the "units"
    column. It is a list so error handling and the caller stay unchanged.
    """
    try:
        # Accept either a live URL or a local .html file path
        if ad_url.lower().startswith(("http://", "https://")):
            html_content, fetch_error = get_html_with_scraperapi(ad_url) # Fetch as string
            if fetch_error:
                return [make_error_row(ad_url, fetch_error)]
        else:
            with open(ad_url, "r", encoding="utf-8", errors="replace") as f:
                html_content = f.read()

        if not html_content:
            return [make_error_row(ad_url, "empty page")]

        soup = BeautifulSoup(html_content, 'html.parser')
        listing_ld = find_json_ld(soup, "VacationRental", "LodgingBusiness", "Hotel") or {}

        # --- PROPERTY NAME ---
        # The <h1> also carries the "Superhostiteľ" award badge and a marketing
        # tagline ("Rodinné apartmány v Kvačanoch"); neither is part of the name.
        propertyName = "Name not found"
        name_tag = soup.find("h1")
        if name_tag:
            title = BeautifulSoup(str(name_tag), "html.parser").find("h1")
            for badge in title.select(".detail-superhost, .detail-promo, .title-above-right"):
                badge.decompose()
            propertyName = title.get_text(" ", strip=True)
        if propertyName in ("", "Name not found"):
            propertyName = listing_ld.get("name") or "Name not found"

        # --- OWNER NAME / PHONE ---
        client_name, phone_number = parse_owner(soup)
        client_name = client_name or "Client name not found"
        phone_number = phone_number or "Phone not found"

        # Extract description
        description = ""
        desc_container = soup.select_one(
            "div.mt.description, div.mt.description-wrapper"
        )
        if desc_container:
            description = desc_container.get_text(" ", strip=True)
            description = re.sub(r"\s+", " ", description)

        print(description[:200] + "...")
        print(client_name)

        # --- ADDRESS & STREET PARSING ---
        # The header reads "<h1>…</h1> Kvačany 231, 032 23, <a>Kvačany (okres …)</a>"
        # i.e. street, postcode, city - and the sheet wants
        # "street, city, postcode, country" with the postcode also on its own.
        city = "City not found"
        streetAndNumber = "Street not found"
        full_address = "Address not found"
        zipCode = ""

        address_div = soup.find("div", class_="f-grow")
        if address_div and address_div.find("h1"):
            header = BeautifulSoup(str(address_div), "html.parser").find("div")
            header.find("h1").decompose()          # leaves only the address text
            raw_address = re.sub(r"\s+", " ", header.get_text(" ", strip=True))
            raw_address = re.sub(r"^,\s*", "", raw_address).strip(" ,")

            city_link = address_div.find("a")
            if city_link:
                city = city_link.get_text(strip=True)

            address_parts = [p.strip() for p in raw_address.split(",") if p.strip()]

            zip_match = re.search(r"\b(\d{3}\s?\d{2})\b", raw_address)
            if zip_match:
                zipCode = zip_match.group(1)

            # The street always leads the address line. It is compared against
            # neither the city nor the postcode, because villages name their
            # main street after themselves ("Tomášikovo, 925 04, Tomášikovo").
            if address_parts and not re.fullmatch(r"\d{3}\s?\d{2}", address_parts[0]):
                streetAndNumber = address_parts[0]

        address_ld = listing_ld.get("address")
        address_ld = address_ld if isinstance(address_ld, dict) else {}
        if streetAndNumber == "Street not found":
            streetAndNumber = address_ld.get("streetAddress", streetAndNumber)
        if city == "City not found":
            city = address_ld.get("addressLocality", city)
        zipCode = zipCode or address_ld.get("postalCode", "")

        country_code = address_ld.get("addressCountry", "")
        Country = COUNTRY_NAMES.get(str(country_code).upper(), country_code or "")

        full_address = ", ".join([p for p in (streetAndNumber, city, zipCode, Country)
                                  if p and not p.endswith("not found")])
        full_address = full_address or "Address not found"

        # --- GEO ---
        # Real coordinates ride along in the JSON-LD; the constants below are
        # only the centre of Slovakia and exist so the column is never empty.
        geo = listing_ld.get("geo")
        geo = geo if isinstance(geo, dict) else {}
        latitude = geo.get("latitude", DEFAULT_LATITUDE)
        longitude = geo.get("longitude", DEFAULT_LONGITUDE)

        # --- EMAIL ---
        # hauzi never prints the host's address on the public page (it is only
        # returned after a booking enquiry), so this normally stays unfound.
        email = listing_ld.get("email") or ""
        if not email:
            mailto = soup.select_one('a[href^="mailto:"]')
            if mailto:
                email = mailto["href"].split("mailto:", 1)[-1].split("?")[0].strip()

        # window.clientData occasionally carries contact details for older listings
        script_tag = soup.find('script', string=re.compile('window.clientData'))
        if script_tag:
            script_content = script_tag.string or ""

            if phone_number == "Phone not found":
                phone_match = re.search(r'"phone"\s*:\s*"([^"]+)"', script_content)
                if phone_match:
                    phone_number = phone_match.group(1)

            if not email:
                email_match = re.search(r'"email"\s*:\s*"([^"]+)"', script_content)
                if email_match:
                    email = email_match.group(1)

        if phone_number == "Phone not found":
            page_text = soup.get_text(" ", strip=True)
            phone_regex = re.search(r'(\+\d{3}\s?\d{3}\s?\d{3}\s?\d{3})', page_text)
            if phone_regex:
                phone_number = phone_regex.group(1)

        # Collapse runs of whitespace but keep the grouping ("+421 918 466 250")
        if phone_number != "Phone not found":
            phone_number = re.sub(r"\s+", " ", phone_number).strip()

        email = email or "Email not found"

        photo_wrapper = soup.find("div", class_="photos-wrapper hide-scrollbar")
        # Remove extra spaces from image URLs
        images = [urljoin(ad_url, img["src"].strip()) for img in photo_wrapper.find_all("img") if img.get("src")] if photo_wrapper else []

        acreage = DEFAULT_ACREAGE
        discount = ""
        doublebed = ""
        kitchen = ""
        nightMax = ""
        nightMin = ""
        person = ""
        singlebed = ""
        userId = ""
        state = ""

         # Extract price and property type
        property_type = "Property type not found"
        # Match any div carrying the "table-prices" class ("table-prices mt3",
        # "table-prices mt", plain "table-prices", ...), skipping the ones inside
        # a unit modal: those are the unit's own prices, not the listing's.
        price_section = next(
            (block for block in soup.select("div.table-prices")
             if not block.find_parent("div", id=re.compile(r"^unit-modal-"))),
            None,
        )

        if price_section:
            property_type_tag = price_section.find("h4")
            if property_type_tag:
                property_type = property_type_tag.text.strip().split()[0]  # Keep only "Apartmán"

        listing_prices = parse_price_table(price_section)
        flexiblePrice = listing_prices["seasons"]
        nightMin = listing_prices["min_nights"]

        # No "Cenník" table: the listing prices its calendar day by day instead,
        # so the seasons are rebuilt from those daily prices.
        if not flexiblePrice:
            flexiblePrice = parse_calendar_seasons(html_content)
            if flexiblePrice:
                print(f"📅 {len(flexiblePrice)} price period(s) taken from the calendar")
                if nightMin == "" and flexiblePrice[0]["min_nights"]:
                    nightMin = flexiblePrice[0]["min_nights"]

        beds = ""
        apartments = ""
        bedroom = ""
        bathroom = ""
        WCs = ""

        main_infos_div = soup.find("div", class_="main-infos")
        priceFriSun = priceMonThus = listing_prices["first_price"] or "Price not found"
        if main_infos_div:
            main_infos = main_infos_div.get_text(" ", strip=True)

            # Max persons
            match = re.search(r"Max\.\s*(\d+)", main_infos, re.I)
            if match:
                person = match.group(1)

            # Extra beds (prístelky / prísteliek)
            match = re.search(r"z toho\s*(\d+)\s*prístel", main_infos, re.I)
            if match:
                beds = match.group(1)

            # Apartments
            match = re.search(r"(\d+)\s*apartmán", main_infos, re.I)
            if match:
                apartments = match.group(1)

            # Bedrooms
            match = re.search(r"(\d+)\s*spál", main_infos, re.I)
            if match:
                bedroom = match.group(1)

            # Bathrooms
            match = re.search(r"(\d+)\s*kúpeľ", main_infos, re.I)
            if match:
                bathroom = match.group(1)

            # WCs
            match = re.search(r"(\d+)\s*x\s*WC", main_infos, re.I)
            if match:
                WCs = match.group(1)

        print(
            f"person={person}, beds={beds}, apartments={apartments}, "
            f"bedroom={bedroom}, bathroom={bathroom}, WCs={WCs}"
        )

        # --- LIVING ROOM (Spoločenská miestnosť) ---
        # Only some properties list a common/living room; multi-unit listings
        # get their own count from the unit's roomText further down.
        page_text = soup.get_text(" ", strip=True)
        page_text = re.sub(r"\s+", " ", page_text.replace("\xa0", " "))
        LivingRoom = count_rooms(page_text, *LIVING_ROOM_PATTERNS) or ""
        if LivingRoom:
            print(f"living room = {LivingRoom}")

        # --- CHECK-IN / CHECK-OUT ---
        # Written either as "od 14:00 - do 17:00" or as a one-sided "od 14:00".
        arrivalFrom = arrivalTo = departureFrom = departureTo = ""

        for row in soup.find_all("tr"):
            cols = row.find_all("td")
            if len(cols) != 2:
                continue

            label = cols[0].get_text(strip=True).lower()
            value = cols[1].get_text(strip=True).lower()

            frm = re.search(r"od\s*(\d{1,2}:\d{2})", value)
            to = re.search(r"do\s*(\d{1,2}:\d{2})", value)

            if "nástup na pobyt" in label or "check-in" in label:
                arrivalFrom = normalize_time(frm.group(1)) if frm else arrivalFrom
                arrivalTo = normalize_time(to.group(1)) if to else arrivalTo

            if "odchod z pobytu" in label or "check-out" in label:
                departureFrom = normalize_time(frm.group(1)) if frm else departureFrom
                departureTo = normalize_time(to.group(1)) if to else departureTo

        # --- PRICE PER NIGHT ---
        # Priority order:
        #   1) The seasonal rate the scrape date falls into ("Letná sezóna
        #      1. júl - 31. aug: 140 €"), because that is what a guest booking
        #      today would actually be quoted.
        #   2) The site's own headline price from the JSON-LD ("od 140 € /
        #      chata / noc").
        #   3) Current calendar cache (embedded JSON): the 1st available day's
        #      price from the current month onwards.
        #   4) The rendered calendar, then the first table price.
        pricePerNight = price_for_today(flexiblePrice)

        if pricePerNight is None:
            price_range = str(listing_ld.get("priceRange") or "")
            pricePerNight = parse_amount(price_range)

        # calendarCache  = per-day availability (0 = unavailable/booked, >0 = bookable)
        # calendarPrices = per-day price
        calendar_cache = []
        calendar_prices = []

        cache_match = re.search(r'"calendarCache"\s*:\s*\[([^\]]*)\]', html_content)
        if cache_match:
            calendar_cache = [int(n) for n in re.findall(r"-?\d+", cache_match.group(1))]

        prices_match = re.search(r'"calendarPrices"\s*:\s*\[([^\]]*)\]', html_content)
        if prices_match:
            calendar_prices = [int(n) for n in re.findall(r"-?\d+", prices_match.group(1))]

        # The calendar arrays start at 1 January of the CURRENT year
        # (index 0 = Jan 1), so index 0 is a stale/past value. Instead we
        # anchor to the 1st day of the CURRENT month and take that day's
        # price; if it is unavailable / has no price we move to the next
        # day, and so on ("current month's 1st value, else the next").
        if pricePerNight is None:
            today = datetime.now().date()
            month_start_index = (today.replace(day=1) - today.replace(month=1, day=1)).days

            for i in range(month_start_index, len(calendar_prices)):
                price = calendar_prices[i]
                available = calendar_cache[i] > 0 if i < len(calendar_cache) else True
                if available and price > 0:
                    pricePerNight = price
                    break

        calendar_wrapper = soup.find("div", class_="calendar-wrapper")

        if pricePerNight is None and calendar_wrapper:
            prices = []

            for block in calendar_wrapper.find_all("div", attrs={"data-date": True}):
                price_tag = block.find("small", class_="cal-price")

                if price_tag:
                    match = re.search(r"(\d+)", price_tag.get_text(strip=True))
                    if match:
                        prices.append(int(match.group(1)))

            if prices:
                pricePerNight = min(prices)

        # Final fallback: no calendar prices -> use the first table price (same as priceFriSun)
        if pricePerNight is None and listing_prices["first_price"]:
            pricePerNight = parse_amount(listing_prices["first_price"])

        # =========================
        # REVIEWS EXTRACTION
        # =========================

        reviewsHeader = ""
        reviewsId = ""
        rating = ""
        reviews_list = []

        # The JSON-LD carries the score as a real number; the visible badge
        # writes it Slovak-style ("4,8") which Excel then reads as 48.
        aggregate = listing_ld.get("aggregateRating")
        if isinstance(aggregate, dict) and aggregate.get("ratingValue") is not None:
            rating = aggregate["ratingValue"]

        review_section = soup.find("div", class_="review-section")

        if review_section:

            # Header
            header_tag = review_section.find("h3", class_="review-title")
            reviewsHeader = header_tag.get_text(strip=True) if header_tag else ""

            # Count (e.g. "7 hodnotení")
            summary_small = review_section.select_one(".review-summary small")
            reviewsId = summary_small.get_text(" ", strip=True) if summary_small else ""

            # Overall rating (4.9)
            if rating == "":
                rating_tag = review_section.find("div", class_="review-score")
                rating = rating_tag.get_text(strip=True).replace(",", ".") if rating_tag else ""

            # Preview reviews only (safe fallback)
            review_cards = review_section.find_all("div", class_="review-preview-card")

            for card in review_cards:
                reviewer = card.find("b")
                review_rating_tag = card.find("span", class_="review-preview-rating")
                review_text_tag = card.find("p", class_="review-preview-text")

                reviews_list.append({
                    "reviewsId": reviewer.get_text(strip=True) if reviewer else "",
                    "rating": review_rating_tag.get_text(" ", strip=True) if review_rating_tag else "",
                    "reviews": review_text_tag.get_text(strip=True) if review_text_tag else ""
                })

        # ALWAYS SAFE OUTPUT (prevents crash / missing variable)
        reviews_json = json.dumps(reviews_list, ensure_ascii=False)

        # If nothing above produced a price, fall back to the cheapest season in
        # the "Cenník pre celý objekt" table.
        if pricePerNight is None and flexiblePrice:
            table_prices = [p["price"] for p in flexiblePrice if p.get("price")]
            if table_prices:
                pricePerNight = min(table_prices)

        def make_row(row_name, row_acreage, row_bathroom, row_bedroom, row_beds,
                     row_images, row_kitchen, row_person, row_doublebed,
                     row_singlebed, row_WCs, row_LivingRoom, row_price=None,
                     row_seasons=None, row_first_price="", row_night_min="",
                     row_units=NO_UNITS):
            """Builds a CSV row; the per-unit values are the only ones that vary.

            Pricing is per-unit when the unit quotes its own Cenník and falls
            back to the listing's numbers when it does not.
            """
            seasons = row_seasons if row_seasons else flexiblePrice
            price = row_price if row_price is not None else pricePerNight
            first_price = row_first_price or priceFriSun
            night_min = row_night_min if row_night_min != "" else nightMin

            # An empty pricing table is a fact ("this listing quotes no
            # seasons"), so it is written as an empty JSON list, not "not found".
            row = [ad_url, row_name, city, full_address, client_name, phone_number,
                   email, row_acreage, arrivalFrom, arrivalTo, row_bathroom,
                   row_bedroom, row_beds, departureFrom, departureTo, description,
                   price, discount, row_doublebed, ",".join(row_images),
                   row_kitchen, nightMax, night_min, row_person, first_price,
                   first_price, row_singlebed, userId, latitude, longitude,
                   zipCode, Country, state,
                   json.dumps(seasons, ensure_ascii=False), row_WCs,
                   row_LivingRoom, reviewsHeader, reviewsId, rating, reviews_json,
                   row_units]
            return [or_not_found(value) for value in row]

        # A property with several apartments/rooms becomes ONE listing with
        # Putko units (A1, A2, …), not one listing per unit: guests pick the
        # unit on the listing page and each unit keeps its own price, capacity,
        # photos and calendar. Address, contact and reviews are the listing's.
        units = parse_units(html_content, soup)
        if len(units) > 1:
            print(f"Found {len(units)} units: {', '.join(u['name'] for u in units)}")
            putko_units = [unit_to_putko(unit) for unit in units]

            # Search and listing cards read the listing's own figures, so they
            # carry the "from" price (cheapest unit) and the largest unit's
            # capacity - a party that fits one unit must still find the listing.
            unit_prices = [u["pricePerNight"] for u in putko_units if u.get("pricePerNight")]
            unit_persons = [u["person"] for u in putko_units if u.get("person")]

            return [make_row(
                propertyName,
                acreage,
                bathroom,
                bedroom,
                beds,
                images or next((u["images"] for u in units if u["images"]), []),
                kitchen,
                max(unit_persons) if unit_persons else person,
                doublebed,
                singlebed,
                WCs,
                LivingRoom,
                min(unit_prices) if unit_prices else None,
                row_units=json.dumps(putko_units, ensure_ascii=False),
            )]

        return [make_row(propertyName, acreage, bathroom, bedroom, beds, images,
                         kitchen, person, doublebed, singlebed, WCs, LivingRoom)]
    except Exception as e:
        print(f"Error extracting details from {ad_url}: {e}")
        return [make_error_row(ad_url, f"{type(e).__name__}: {e}")]


def normalize_url(value):
    """Key used to tell two links apart.

    Hand-maintained link lists pick the same listing up more than once with
    cosmetic differences ("/penzion-maria", "/penzion-maria/", "?utm_source=..."),
    so trailing slashes, the query string, the fragment and the scheme/host case
    are all stripped before comparing.
    """
    split = urlsplit(value.strip())
    if not split.scheme:
        return value.strip().lower()
    path = split.path.rstrip("/") or "/"
    return urlunsplit((split.scheme.lower(), split.netloc.lower(), path, "", ""))


def read_links_from_csv(filepath="links.csv"):
    """Reads URLs from a CSV file and returns a de-duplicated list of URLs.

    A listing repeated in the input used to be scraped once per occurrence -
    wasted API credits and a duplicate listing on import for every repeat.
    Duplicates are dropped here, keeping
    the first occurrence so the output keeps the input's order.
    """
    urls = []
    seen = {}
    with open(filepath, mode='r', newline='', encoding='utf-8-sig') as file:
        reader = csv.reader(file)
        for row in reader:
            if not row:
                continue

            value = row[0].strip()
            # Drops the "link" / "url" column header and any stray label cells,
            # which would otherwise be scraped as if they were addresses
            if value.lower().startswith(("http://", "https://")) or value.lower().endswith(".html"):
                key = normalize_url(value)
                if key in seen:
                    seen[key] += 1
                    continue
                seen[key] = 1
                urls.append(value)
            elif value:
                print(f"⏭️  Skipping non-URL entry: {value!r}")

    repeats = {url: seen[normalize_url(url)] for url in urls
               if seen[normalize_url(url)] > 1}
    if repeats:
        extra = sum(n - 1 for n in repeats.values())
        print(f"⏭️  Ignored {extra} duplicate link(s) in {os.path.basename(filepath)}:")
        for url, count in sorted(repeats.items(), key=lambda kv: -kv[1]):
            print(f"   • {url}  (listed {count}x)")
    return urls


def dedupe_rows(all_data):
    """Drops rows that repeat a unit already emitted, keeping the first of each.

    Second line of defence behind read_links_from_csv: a listing reached twice
    (a redirect, an old slug, a link written two different ways) would otherwise
    repeat its whole unit block. propertyUrl is left out of the key on purpose -
    those two links spell the same listing differently, so comparing whole rows
    would find nothing to collapse and every unit would be written twice.

    Everything else must match exactly, so real units survive: Penzión Mária
    genuinely has two units both called "Rodinná izba - hlavná budova", and
    those differ in capacity (4 vs 5 people).
    """
    seen = set()
    unique = []
    for row in all_data:
        # Error rows are "not found" in every column but the URL and the
        # message, so two links failing the same way look like duplicates of
        # each other. They are one per link already, so never drop them.
        if str(row[1]).startswith(ERROR_PREFIX):
            unique.append(row)
            continue

        # Column 0 is propertyUrl; see the docstring for why it is excluded.
        key = tuple(str(value) for value in row[1:])
        if key in seen:
            continue
        seen.add(key)
        unique.append(row)
    return unique


def save_to_csv(all_data, filename="hauzi_extracted.csv"):
    """Saves all extracted data into a CSV file."""
    # utf-8-sig writes a BOM so Excel / Google Sheets render Slovak accents
    # (á, č, ž, ...) correctly instead of mojibake like "ApartmÃ¡n"
    with open(filename, mode='w', newline='', encoding='utf-8-sig', errors='replace') as file:
        writer = csv.writer(file)
        writer.writerow(CSV_HEADERS)
        writer.writerows(all_data)


def script_dir():
    """Directory holding this script, or the working directory in a notebook.

    __file__ does not exist when the code is pasted into Jupyter / IPython,
    so fall back to the current directory there.
    """
    try:
        return os.path.dirname(os.path.abspath(__file__))
    except NameError:
        return os.getcwd()


def cli_args():
    """sys.argv without the interpreter, or [] when run interactively.

    Jupyter fills sys.argv with kernel options ("-f .../kernel.json"), which
    would otherwise be picked up as the input filename.
    """
    if any(a.startswith("-") for a in sys.argv[1:]):
        return []
    return sys.argv[1:]


def main():
    # Defaults to the links file next to this script; override on the command
    # line ("python Hazui.py my-links.csv out.csv").
    here = script_dir()
    args = cli_args()
    input_file = args[0] if len(args) > 0 else os.path.join(here, "links (1).csv")
    output_file = args[1] if len(args) > 1 else "hauzi_extracted.csv"

    urls = read_links_from_csv(input_file)
    print(f"Found {len(urls)} links. Starting scraping...")

    all_data = []
    failures = []
    for url in urls:
        print(f"Scraping: {url}")
        # One row per listing; a multi-unit one carries its units in "units"
        rows = scrape_ad_details(url) or []
        all_data.extend(rows)

        for row in rows:
            if str(row[1]).startswith(ERROR_PREFIX):
                failures.append((url, str(row[1])[len(ERROR_PREFIX):]))

        # IMPORTANT: Add a delay to avoid API credit burnout
        time.sleep(random.uniform(2, 5))

    deduped = dedupe_rows(all_data)
    if len(deduped) != len(all_data):
        print(f"\n⏭️  Dropped {len(all_data) - len(deduped)} duplicate row(s).")

    save_to_csv(deduped, output_file)
    print(f"\n✅ Data extraction complete. {len(deduped)} rows saved to {output_file}")

    # Repeat the failures at the end - they scroll far out of sight otherwise
    if failures:
        print(f"\n⚠️  {len(failures)} of {len(urls)} links failed:")
        for url, reason in failures:
            print(f"   • {url}  ->  {reason}")
        print("   (these are in the CSV too, with propertyName starting 'ERROR:')")


if __name__ == "__main__":
    main()
