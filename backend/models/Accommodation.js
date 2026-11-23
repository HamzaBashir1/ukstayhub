import mongoose from 'mongoose';
import { validateCustomTiers } from '../utils/cancellationPolicy.js';
import { bumpPinCacheVersion } from '../utils/pinCache.js';
import { contentUpdatedAtPlugin, LISTING_CONTENT_FIELDS } from '../utils/contentUpdatedAt.js';

// One seasonal offer: a date range with length-of-stay / guest-range price
// rows. A factory so the listing and its units each get their own copy of
// the definition.
const flexiblePricePeriodShape = () => ({
  _id: false,
  name: { type: String, required: false },
  start: { type: Date, required: false },
  end: { type: Date, required: false },
  note: { type: String, required: false },
  // Whether the host's length/guest discounts also come off this offer's
  // price. Defaults to true, which is how offers behaved before the flag.
  applyDiscounts: { type: Boolean, default: true },
  // Extra-bed price per guest per night above the listing's includedGuests,
  // for this offer's dates. Null/absent uses the listing's pricePerPerson.
  extraPerPerson: { type: Number, required: false, default: null, min: 0 },
  tiers: {
    type: [
      {
        _id: false,
        minNights: { type: Number, required: false, default: 1 },
        maxNights: { type: Number, required: false, default: null },
        // Optional guest range (adults + children). Null/absent means
        // any number of guests.
        minGuests: { type: Number, required: false, default: null },
        maxGuests: { type: Number, required: false, default: null },
        price: { type: Number, required: false },
        // Price for a weekend night (see the listing's weekendDays). Null/0
        // charges `price` every night.
        weekendPrice: { type: Number, required: false, default: null, min: 0 }
      }
    ],
    default: []
  }
});

// A multi-select amenity group stored as two parallel arrays, the shape every
// amenity field on the listing uses. Not enum-validated here: the publish
// mapper only ever writes values it has matched against the listing's enums.
const amenityPairShape = () => ({
  _id: false,
  en: { type: [String], default: undefined },
  sk: { type: [String], default: undefined },
});

/**
 * One bookable unit inside a listing — e.g. "Apartment A1" and "Apartment A2"
 * under "Apartments A". Every field is optional except the name: a value left
 * unset falls back to the listing's own (see utils/listingUnits.js), so a unit
 * only has to state what makes it different.
 *
 * The `_id` is stable across republishes (the editor keeps it), because
 * reservations and calendar rows point at it.
 */
const unitSchema = new mongoose.Schema({
  name: { type: String, required: true, trim: true },
  description: { type: String },
  person: { type: Number, min: 0 },
  bedroom: { type: Number, min: 0 },
  beds: { type: Number, min: 0 },
  extraBeds: { type: Number, min: 0 },
  singlebed: { type: Number, min: 0 },
  doublebed: { type: Number, min: 0 },
  bunkbed: { type: Number, min: 0 },
  bathroom: { type: Number, min: 0 },
  LivingRoom: { type: Number, min: 0 },
  kitchen: { type: Number, min: 0 },
  pricePerNight: { type: Number, min: 0 },
  pricePerPerson: { type: Number, min: 0 },
  // Unit's own weekend rate / guests included; unset falls back to the listing
  // (the weekend rate only when the unit also uses the listing's nightly price).
  weekendPricePerNight: { type: Number, min: 0 },
  includedGuests: { type: Number, min: 0 },
  cleaningFee: { type: Number, min: 0 },
  // The unit's own seasonal offers. Only used when the unit has its own
  // nightly price; otherwise it is priced exactly like the listing.
  flexiblePrices: { type: [flexiblePricePeriodShape()], default: undefined },
  services: amenityPairShape(),
  bathroomAmenities: amenityPairShape(),
  kitchenDiningAmenities: amenityPairShape(),
  heatingCoolingAmenities: amenityPairShape(),
  safetyAmenities: amenityPairShape(),
  wellnessAmenities: amenityPairShape(),
  outdoorAmenities: amenityPairShape(),
  parkingFacilities: amenityPairShape(),
  images: { type: [String], default: undefined },
});

const accommodationSchema = new mongoose.Schema({
  name: {
    type: String,
    required: false,
    index: true,
  },
  slug: { type: String, required: true, unique: true, index: true, },
  description: {
    type: String
  },
  // English text for the same listing. The Slovak fields above stay the
  // source of truth; the /en pages show these and fall back to Slovak per field.
  translations: {
    en: {
      name: { type: String },
      description: { type: String },
      specialNote: { type: String },
    },
  },
  specialNote: {
    type: String,
    required: false
  },
  // Free-text description shown on the listing page. Kept as-is so existing
  // listings and the current UI are unaffected.
  cancellationPolicy: {
    type: String,
    required: false
  },
  // Machine-readable policy that actually drives refunds. Separate from the
  // free-text field above so no existing data has to be migrated or reinterpreted.
  cancellationPolicyType: {
    type: String,
    enum: ['flexible', 'standard', 'strict', 'custom', 'new_year_special', 'non_refundable'],
    default: 'standard',
    index: true,
  },
  // Only meaningful when cancellationPolicyType === 'custom'.
  // Always stored in HOURS before check-in — a 48-hour boundary cannot be
  // expressed precisely in days. Max 3 tiers, sorted descending, last tier
  // must be { hoursBefore: 0, refundPercent: 0 } so no-shows never refund.
  customPolicyTiers: {
    type: [
      {
        _id: false,
        hoursBefore: { type: Number, required: true, min: 0 },
        refundPercent: { type: Number, required: true, min: 0, max: 100 },
      },
    ],
    default: undefined,
  },
  // Legacy single-feed field – kept only for migration. Prefer calendarSync[].
  url: { type: String },
  virtualTourUrl: { type: String },
  propertyType: {
    en: {
      type: String,
      required: true,
      index: true,
      enum: [
        "Nature House", "Wooden House", "Houseboats", "Farm House", "Dome House",
        "Wooden Dome", "Apartment", "Glamping", "Cottages", "Motels/Hostel",
        "Wooden Houses", "Guest Houses", "Secluded Accommodation", "Hotels",
        "Dormitories", "Campsites", "Treehouses", "Rooms", "Entire Homes",
        "Luxury Accommodation"
      ]
    },
    sk: {
      type: String,
      required: true,
      index: true,
      enum: [
        "Prírodný dom", "Drevený dom", "Hausbóty", "Farma", "Kupolový dom",
        "Drevená kupola", "Apartmán", "Glamping", "Chaty", "Motely/Hostely",
        "Drevené domy", "Penzióny", "Odľahlé ubytovanie", "Hotely",
        "Ubytovne", "Kempingy", "Domy na strome", "Izby", "Celé domy",
        "Luxusné ubytovanie"
      ]
    }
  },

  rentalform: {
    en: {
      type: String,
      enum: ["Entire place", "Private room", "Share room"],
      index: true,
    },
    sk: {
      type: String,
      enum: ["Celé miesto", "Súkromná izba", "Zdieľaná izba"],
      index: true,
    },
  },
  excludedDates: {
    type: [Date], // Array of Date objects
    default: [],
  },
  specialPrice: {
    name: { type: String, required: false },
    start: { type: Date, required: false },
    end: { type: Date, required: false },
    price: { type: Number, required: false }
  },
  // Flexible seasonal pricing. Each period covers a date range and holds one or
  // more length-of-stay tiers, e.g. Summer 1-3 nights €120, 4-6 €105, 7+ €95.
  // A tier with maxNights null/absent means "and above". A tier can also be
  // limited to a guest range (minGuests/maxGuests), e.g. 2-4 guests. Takes
  // precedence over specialPrice, which itself takes precedence over
  // pricePerNight.
  flexiblePrices: {
    type: [flexiblePricePeriodShape()],
    default: []
  },
  // Optional sub-units (A1, A2, …) a guest chooses between on the listing page.
  // Absent on every listing that does not use them, which then books exactly
  // as before.
  units: { type: [unitSchema], default: undefined },
  discount: { type: Number, required: false },
  // Percentage discounts on the nights' price (not on cleaning fee, local tax
  // or pet fee). In each list the row with the highest threshold the stay
  // reaches applies; a length and a guest discount add up, capped at 90 %.
  // Empty (the default) means no discount, so listings without them are
  // priced exactly as before.
  lengthDiscounts: {
    type: [
      {
        _id: false,
        minNights: { type: Number, required: false },
        percent: { type: Number, required: false, min: 0, max: 90 },
      },
    ],
    default: [],
  },
  guestDiscounts: {
    type: [
      {
        _id: false,
        minGuests: { type: Number, required: false },
        percent: { type: Number, required: false, min: 0, max: 90 },
      },
    ],
    default: [],
  },
  pricePerNight: { type: Number, required: false },
  pricePerPerson: { type: Number, required: false },
  // Weekend pricing: nights starting on `weekendDays` (0 = Sunday … 6 =
  // Saturday; empty = Friday + Saturday) cost `weekendPricePerNight` instead of
  // `pricePerNight`. 0/unset = no weekend rate. Offers have their own per row.
  weekendPricePerNight: { type: Number, required: false, default: 0, min: 0 },
  weekendDays: { type: [Number], default: undefined },
  // How many paying guests the nightly price covers (e.g. 2 in the standard
  // beds). Each guest above it pays pricePerPerson per night on top (extra
  // bed). 0/unset keeps the legacy rule max(pricePerNight, pricePerPerson × guests).
  includedGuests: { type: Number, required: false, default: 0, min: 0 },
  // Optional extras added to the stay total. 0 (or unset) means none.
  // cleaningFee is charged once per stay; localTaxPerPersonNight is charged per
  // paying guest (adults + children) per night.
  cleaningFee: { type: Number, required: false, default: 0, min: 0 },
  localTaxPerPersonNight: { type: Number, required: false, default: 0, min: 0 },
  // Amenities the guest can add for a price (hot tub, sauna, …), chosen at
  // booking. `field` is the amenity group, `amenity` its { en, sk } value;
  // `pricing` is per night or once per stay. Never charged unless picked.
  paidExtras: {
    type: [
      {
        _id: false,
        field: { type: String },
        amenity: { en: { type: String }, sk: { type: String } },
        pricing: { type: String, enum: ["per_night", "per_stay"], default: "per_stay" },
        price: { type: Number, min: 0 },
      },
    ],
    default: undefined,
  },
  location: {
    address: { type: String, required: false, index: true },
    latitude: { type: Number },
    longitude: { type: Number }
  },
  acreage: { type: String },
  tags: { type: [String], default: [] },
  nightMin: { type: Number, required: true, index: true },
  nightMax: { type: Number, required: false, index: true, default: null },
  beds: { type: Number, index: true },
  singlebed: { type: Number, index: true },
  doublebed: { type: Number, index: true },
  bunkbed: { type: Number, index: true, default: 0 },
  kitchen: { type: Number, index: true },
  WCs: { type: Number, index: true },
  SocialRoom: { type: Number, index: true },
  CommonRoom: { type: Number, index: true },
  LivingRoom: { type: Number, index: true },
  Sofa: { type: Number, index: true },
  bedroom: { type: Number, index: true },
  bathroom: { type: Number, index: true },
  person: { type: Number, required: true, index: true },
  recommended: {
    type: Boolean,
    default: false,
    index: true
  },

  // ── Listing status (Stripe-driven) ───────────────────────────────────────
  status: {
    type: String,
    enum: ['DRAFT', 'PENDING', 'PUBLISHED'],
    default: 'DRAFT',
    index: true,
  },
  stripeAccountId: {
    type: String,
    required: false,
    index: true,
  },
  stripeStatus: {
    type: String,
    enum: ['not_connected', 'pending', 'active', 'restricted'],
    default: 'not_connected',
    index: true,
  },
  stripeRequirements: {
    type: String,
    required: false,
  },
  stripeEnabled: {
    type: Boolean,
    default: true,
    index: true,
  },

  /**
   * Lifecycle, driven by the host's Stripe account — never set by hand.
   *
   *   DRAFT      details saved, no Stripe account linked yet
   *   PENDING    account linked, Stripe still verifying
   *   PUBLISHED  Stripe reports charges_enabled + payouts_enabled
   *
   * Recomputed from the `account.updated` webhook, so a listing goes live the
   * moment its own host finishes onboarding. See utils/listingStatus.js.
   *
   * No value means DRAFT. A listing with nothing stored has, by definition,
   * never had a payout account linked to it — which is what DRAFT says.
   *
   * Mongoose only applies a default to a MISSING path, so a listing already
   * carrying PENDING or PUBLISHED keeps it through any save; the default can
   * only ever fill a blank.
   *
   * The value moves on its own: `account.updated` when Stripe verifies the
   * account, and when the host completes their billing details. Nothing
   * publishes a listing by hand.
   */
  listingStatus: {
    type: String,
    enum: ["DRAFT", "PENDING", "PUBLISHED"],
    default: "DRAFT",
    index: true,
  },
  listingStatusUpdatedAt: { type: Date },

  /**
   * Which of the host's connected accounts THIS listing pays out to.
   *
   * Null means "the host's default account" — which is what every listing that
   * predates multiple accounts means, and what a host running one account for
   * everything will always mean. Set it only when a property is deliberately
   * pointed at a different account.
   *
   * Must be one of the accountIds on the host's `stripeAccounts`; a listing
   * naming an account its host does not hold falls back to the default rather
   * than paying a stranger.
   */
  payoutStripeAccountId: { type: String, index: true },

  // ── Multi calendar sync ──────────────────────────────────────────────────
  /**
   * External iCal feeds (Airbnb, Booking.com, …).
   * One source of truth used by the add-form and the sidebar overview.
   */
  calendarSync: {
    type: [
      {
        url: { type: String, required: true, trim: true },
        label: { type: String, trim: true },          // optional "Airbnb", "Booking"…
        lastSyncAt: { type: Date },
        lastSyncStatus: {
          type: String,
          enum: ['ok', 'error', 'never'],
          default: 'never',
        },
        lastSyncError: { type: String },
        lastImportedCount: { type: Number, default: 0 },
        // On a listing split into units: the unit this calendar belongs to,
        // so its dates block only that unit. Unset (every feed connected
        // before units existed) means the whole listing, as it always has.
        unitId: { type: mongoose.Schema.Types.ObjectId, required: false },
      },
    ],
    default: [],
  },
  /**
   * Putko’s own export URL for this listing.
   * Generated after draft autosave / first feed add.
   */
  icalExportUrl: { type: String },

  locationDetails: {
    streetAndNumber: {
      type: String,
      index: true,
      set: (value) => value?.toLowerCase()
    },
    roomNumber: {
      type: String,
      index: true,
      set: (value) => value?.toLowerCase()
    },
    city: {
      type: String,
      index: true,
      set: (value) => value?.toLowerCase()
    },
    zipCode: {
      type: String,
      index: true,
    },
    country: {
      type: String,
      index: true,
    },
    state: {
      type: String,
      index: true,
      set: (value) => value?.toLowerCase()
    },
  },
  userId: {
    type: mongoose.Schema.Types.ObjectId,
    ref: 'Host',
    required: true
  },
  phoneNumber: { type: String, required: true },
  arrivalFrom: { type: String, required: false },
  arrivalTo: { type: String, required: false },
  departureFrom: { type: String, required: false },
  departureTo: { type: String, required: false },
  services: {
    en: {
      index: true,
      type: [String],
      enum: ["Wifi", "TV", "PC Desk(workspace)"],
    },
    sk: {
      index: true,
      type: [String],
      enum: ["Wifi", "TV", "PC stôl(pracovný priestor)"],
    },
  },
  bathroomAmenities: {
    en: {
      index: true,
      type: [String],
      enum: ["Bathtub", "Shower", "Washing Machine", "Dryer", "Ironing"],
    },
    sk: {
      index: true,
      type: [String],
      enum: ["Vaňa", "Sprcha", "Práčka", "Sušička", "Žehlenie"],
    },
  },
  kitchenDiningAmenities: {
    en: {
      index: true,
      type: [String],
      enum: [
        "Stovetop",
        "Oven",
        "Dishwasher",
        "Refrigerator",
        "Freezer",
        "Dining Table",
        "Coffee Maker",
      ],
    },
    sk: {
      index: true,
      type: [String],
      enum: [
        "Varná doska",
        "Rúra",
        "Umývačka riadu",
        "Chladnička",
        "Mraznička",
        "Jedálenský stôl",
        "Kávovar",
      ],
    },
  },
  heatingCoolingAmenities: {
    en: {
      index: true,
      type: [String],
      enum: ["Indoor Fireplace", "Air Conditioning", "Central Heating"],
    },
    sk: {
      index: true,
      type: [String],
      enum: ["Vnútorný krb", "Klimatizácia", "Ústredné kúrenie"],
    },
  },

  safetyAmenities: {
    en: {
      index: true,
      type: [String],
      enum: ["Fire Extinguisher", "First Aid Kit"],
    },
    sk: {
      index: true,
      type: [String],
      enum: ["Hasiaci prístroj", "Lekárnička"],
    },
  },
  wellnessAmenities: {
    en: {
      index: true,
      type: [String],
      enum: ["Sauna", "Hot Tub", "Indoor Pool", "Outdoor Pool", "None"],
    },
    sk: {
      index: true,
      type: [String],
      enum: ["Sauna", "Vírivka", "Vnútorný bazén", "Vonkajší bazén", "Žiadne"],
    },
  },

  outdoorAmenities: {
    en: {
      index: true,
      type: [String],
      enum: [
        "Firepit",
        "Balcony",
        "Terrace",
        "Outdoor dining area",
        "Grill",
        "None",
      ],
    },
    sk: {
      index: true,
      type: [String],
      enum: [
        "Ohnisko",
        "Balkón",
        "Terasa",
        "Vonkajší jedálenský priestor",
        "Gril",
        "Žiadne",
      ],
    },
  },
  parkingFacilities: {
    en: {
      index: true,
      type: [String],
      enum: ["Free Parking on-site", "Paid Parking on-site", "Public Parking"],
    },
    sk: {
      index: true,
      type: [String],
      enum: ["Bezplatné parkovanie na mieste", "Platené parkovanie", "Verejné parkovanie"],
    },
  },
  checkIn: {
    en: {
      index: true,
      type: [String],
      enum: ["Self Check-in", "Reception", "Host Greeting"],
    },
    sk: {
      index: true,
      type: [String],
      enum: ["Samoobslužný check-in", "Recepcia", "Privítanie hostiteľom"],
    },
  },
  meals: {
    en: {
      index: true,
      type: [String],
      enum: [
        "No Meals",
        "Breakfast",
        "Half Board",
        "Full Board",
        "All-Inclusive",
      ],
    },
    sk: {
      index: true,
      type: [String],
      enum: [
        "Bez stravy",
        "Raňajky",
        "Polpenzia",
        "Plná penzia",
        "All-inclusive",
      ],
    },
  },

  pet: {
    en: {
      type: String,
      index: true,
      enum: [
        "Allowed at no extra charge",
        "Allowed with an additional fee",
        "Allowed for a fee by arrangement with the owner",
        "Not Allowed",
      ],
    },
    sk: {
      type: String,
      index: true,
      enum: [
        "Povolené bez príplatku",
        "Povolené za príplatok",
        "Povolené za poplatok po dohode s majiteľom",
        "Nepovolené",
      ],
    },
  },

  // Optional. Only meaningful when pet.en === "Allowed with an additional fee";
  // 0 means pets are allowed without an extra charge.
  petFeePerNight: {
    type: Number,
    required: false,
    default: 0,
    min: 0,
  },

  partyOrganizing: {
    en: {
      type: String,
      index: true,
      enum: ["Allowed", "Not Allowed"],
    },
    sk: {
      type: String,
      index: true,
      enum: ["Povolené", "Nepovolené"],
    },
  },
  smoking: {
    en: {
      type: String,
      index: true,
      enum: [
        "Allowed indoors",
        "Allowed in designated areas",
        "Not allowed",
      ],
    },
    sk: {
      type: String,
      index: true,
      enum: [
        "Povolené v interiéri",
        "Povolené v určených priestoroch",
        "Nepovolené",
      ],
    },
  },
  images: [{ type: String }],
  reviews: [{ type: mongoose.Types.ObjectId, ref: "Review" }],
  averageRating: {
    type: Number,
    default: 0,
  },
  Reservation: [{ type: mongoose.Types.ObjectId, ref: "Reservation" }],
  occupancyCalendar: [
    {
      startDate: { type: Date, required: false },
      endDate: { type: Date, required: false },
      guestName: { type: String, default: 'N/A' },
      status: {
        type: String,
        enum: ['booked', 'available', 'blocked', 'held'],
        default: 'booked'
      },
      holdExpiresAt: { type: Date, required: false },
      reservationId: {
        type: mongoose.Schema.Types.ObjectId,
        ref: 'Reservation',
        required: false
      },
      // Only 'ics' rows are swept when a host disconnects a feed
      source: {
        type: String,
        enum: ['manual', 'ics', 'reservation'],
        default: 'manual'
      },
      // Which calendarSync entry produced this row (precise cleanup)
      calendarSyncId: {
        type: mongoose.Schema.Types.ObjectId,
        required: false,
      },
      // The unit this row occupies. Unset means the whole listing (manual
      // blocks, imported feeds, and every row on a listing without units).
      unitId: {
        type: mongoose.Schema.Types.ObjectId,
        required: false,
      },
      unitName: { type: String, required: false },
    }
  ],
  views: { type: Number, default: 0 },
  clicks: { type: Number, default: 0 },
  customerInterest: { type: Number, default: 0 },
  isApproved: {
    type: Boolean,
    default: false,
  },
  date: {
    type: Date,
    default: Date.now
  }
}, { timestamps: true });

// Sitemap lastmod: moves only when something shown on the listing page changes.
accommodationSchema.plugin(contentUpdatedAtPlugin, { fields: LISTING_CONTENT_FIELDS });

// Reject an invalid custom cancellation policy at save time
accommodationSchema.pre('validate', function validateCustomPolicy(next) {
  if (this.cancellationPolicyType !== 'custom') return next();

  const { valid, errors, tiers } = validateCustomTiers(this.customPolicyTiers);
  if (!valid) {
    return next(new Error(`Invalid custom cancellation policy: ${errors.join('; ')}`));
  }

  this.customPolicyTiers = tiers;
  next();
});

// ---------------------------------------------------------------------------
// Map-pin cache invalidation.
//
// Registered on the schema rather than at the ~35 call sites that write to this
// collection (controllers, the calendar-hold helpers, the review hooks, the
// Stripe sync, the host importer, the cleanup job). Hooking the model means
// every existing write path invalidates automatically, and so does every one
// added later — there is no list to keep in sync.
//
// Fire-and-forget inside; a cache bump must never delay or fail the write.
// ---------------------------------------------------------------------------
// Only invalidate when a write actually CHANGED something.
//
// This matters more than it looks: utils/cleanupJob.js runs
// `Accommodation.deleteMany(...)` on a "*/5 * * * * *" schedule — six fields, so
// every five seconds — and it almost always deletes nothing. Mongoose fires the
// post hook regardless, so a naive bump threw the whole pin cache away every
// five seconds and the cache never survived long enough to be used.
const changedSomething = (res) => {
  if (res == null) return false;
  if (Array.isArray(res)) return res.length > 0;                    // insertMany
  if (typeof res.deletedCount === "number") return res.deletedCount > 0;
  if (typeof res.modifiedCount === "number") {
    return res.modifiedCount > 0 || (res.upsertedCount || 0) > 0;
  }
  return true; // findOneAndUpdate/Delete/Replace resolved to a document
};

const invalidatePinCache = function (res) {
  if (changedSomething(res)) bumpPinCacheVersion();
};

// Document middleware: accommodation.save() — a completed save always changed
// something, so this one bumps unconditionally.
accommodationSchema.post('save', function () {
  bumpPinCacheVersion();
});

// Bulk insert: Accommodation.insertMany(...)
accommodationSchema.post('insertMany', invalidatePinCache);

// Query middleware. `updateOne`/`deleteOne` are registered explicitly as query
// middleware — Mongoose can interpret those two names as either document or
// query hooks, so the intent is stated rather than left to the default.
accommodationSchema.post(
  [
    'findOneAndUpdate',
    'findOneAndDelete',
    'findOneAndReplace',
    'updateOne',
    'updateMany',
    'replaceOne',
    'deleteOne',
    'deleteMany',
  ],
  { document: false, query: true },
  invalidatePinCache
);

/**
 * The listing's reviews, resolved from the Review collection by accommodation id
 * — the same query GET /reviews/:accommodationId runs, which is what the listing
 * page averages.
 *
 * The `reviews` ObjectId array above is a denormalised copy and is NOT reliable
 * as a source of truth: createReview `$push`es into it (so a double submit can
 * list the same review twice, double-weighting it in an average), and nothing
 * `$pull`s on delete. A card scoring a listing from that array could therefore
 * land on a different number than the listing page it opens. Populate this
 * virtual instead and the two read the same rows by construction.
 */
accommodationSchema.virtual('reviewDocs', {
  ref: 'Review',
  localField: '_id',
  foreignField: 'accommodation',
});

export default mongoose.model('Accommodation', accommodationSchema);