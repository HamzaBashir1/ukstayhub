import mongoose from 'mongoose';

const DeletedAccommodationSchema = new mongoose.Schema({
  name: {
    type: String,
    required: false
  },
  slug: { type: String, required: true, unique: true },
  description: {
    type: String
  },
  specialNote: {
    type: String,
    required: false
  },
  cancellationPolicy: {
    type: String,
    required: false
  },
  url: {
    type: String
  },
  virtualTourUrl: {
    type: String
  },
  propertyType: {
    en: {
      type: String,
      required: true,
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
    },
    sk: {
      type: String,
      enum: ["Celé miesto", "Súkromná izba", "Zdieľaná izba"],
    },
  },
  excludedDates: {
    type: [Date], // Array of Date objects
    default: [],
  },
  // FixedPrice: {
  //   type: Number,
  //   required: false
  // },
  specialPrice: {
    start: {
      type: Date,
      required: false
    },
    end: {
      type: Date,
      required: false
    },
    price: {
      type: Number,
      required: false
    }
  },
  // Mirrors Accommodation.units (stored loosely) so a soft-deleted listing
  // keeps its sub-units and restores with them.
  units: { type: [mongoose.Schema.Types.Mixed], default: undefined },
  // Mirrors Accommodation.flexiblePrices so a soft-deleted listing keeps its
  // seasonal rates and can be restored without losing them.
  flexiblePrices: {
    type: [
      {
        _id: false,
        name: {
          type: String,
          required: false
        },
        start: {
          type: Date,
          required: false
        },
        end: {
          type: Date,
          required: false
        },
        note: {
          type: String,
          required: false
        },
        applyDiscounts: {
          type: Boolean,
          default: true
        },
        tiers: {
          type: [
            {
              _id: false,
              minNights: {
                type: Number,
                required: false,
                default: 1
              },
              maxNights: {
                type: Number,
                required: false,
                default: null
              },
              minGuests: {
                type: Number,
                required: false,
                default: null
              },
              maxGuests: {
                type: Number,
                required: false,
                default: null
              },
              price: {
                type: Number,
                required: false
              }
            }
          ],
          default: []
        }
      }
    ],
    default: []
  },
  discount: {
    type: Number,
    required: false
  },
  // Mirrors Accommodation.lengthDiscounts / guestDiscounts.
  lengthDiscounts: {
    type: [
      {
        _id: false,
        minNights: { type: Number, required: false },
        percent: { type: Number, required: false }
      }
    ],
    default: []
  },
  guestDiscounts: {
    type: [
      {
        _id: false,
        minGuests: { type: Number, required: false },
        percent: { type: Number, required: false }
      }
    ],
    default: []
  },
  pricePerNight: {
    type: Number,
    required: false
  },
  pricePerPerson: {
    type: Number,
    required: false
  },
  cleaningFee: {
    type: Number,
    required: false,
    default: 0
  },
  localTaxPerPersonNight: {
    type: Number,
    required: false,
    default: 0
  },
  paidExtras: {
    type: mongoose.Schema.Types.Mixed,
    default: undefined
  },
  location: {
    address: {
      type: String,
      required: false
    },
    latitude: {
      type: Number
    },
    longitude: {
      type: Number
    }
  },
  acreage: {
    type: String,
  },
  tags: { type: [String], default: [] },
  nightMin: { type: Number, required: true },
  nightMax: { type: Number, required: false, index: true, default: null },
  beds: { type: Number, },
  singlebed: { type: Number },
  bunkbed: { type: Number, default: 0 },
  doublebed: { type: Number },
  kitchen: { type: Number, },
  WCs: { type: Number, },
  SocialRoom: { type: Number, },
  CommonRoom: { type: Number, },
  LivingRoom: { type: Number, },
  bedroom: { type: Number, },  // Number of bedrooms
  bathroom: { type: Number, }, // Number of bathrooms
  person: { type: Number, required: true },
  locationDetails: {
    streetAndNumber: {
      type: String,
      set: (value) => value?.toLowerCase()
    },
    roomNumber: {
      type: String,
      set: (value) => value?.toLowerCase()
    },
    city: {
      type: String,
      set: (value) => value?.toLowerCase()
    },
    zipCode: {
      type: String
    },
    country: {
      type: String
    },
    state: {
      type: String,
      set: (value) => value?.toLowerCase()
    },
  },
  // Add userId to reference the user who created the accommodation
  userId: {
    type: mongoose.Schema.Types.ObjectId,
    ref: 'Host', // Reference to the User model
    required: true // Ensure that every accommodation has a user associated with it
  },
  phoneNumber: { type: String, required: true },
  arrivalFrom: {
    type: String, // Store as a string in "HH:MM" format
    required: false,
  },
  arrivalTo: {
    type: String, // Store as a string in "HH:MM" format
    required: false,
  },
  departureFrom: {
    type: String, // Store as a string in "HH:MM" format
    required: false,
  },
  departureTo: {
    type: String, // Store as a string in "HH:MM" format
    required: false,
  },
  services: {
    en: {
      type: [String],
      enum: ["Wifi", "TV", "PC Desk(workspace)"],
    },
    sk: {
      type: [String],
      enum: ["Wifi", "TV", "PC stôl(pracovný priestor)"],
    },
  },
  bathroomAmenities: {
    en: {
      type: [String],
      enum: ["Bathtub", "Shower", "Washing Machine", "Dryer", "Ironing"],
    },
    sk: {
      type: [String],
      enum: ["Vaňa", "Sprcha", "Práčka", "Sušička", "Žehlenie"],
    },
  },
  kitchenDiningAmenities: {
    en: {
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
      type: [String],
      enum: ["Indoor Fireplace", "Air Conditioning", "Central Heating"],
    },
    sk: {
      type: [String],
      enum: ["Vnútorný krb", "Klimatizácia", "Ústredné kúrenie"],
    },
  },

  safetyAmenities: {
    en: {
      type: [String],
      enum: ["Fire Extinguisher", "First Aid Kit"],
    },
    sk: {
      type: [String],
      enum: ["Hasiaci prístroj", "Lekárnička"],
    },
  },

  wellnessAmenities: {
    en: {
      type: [String],
      enum: ["Sauna", "Hot Tub", "Indoor Pool", "Outdoor Pool", "None"],
    },
    sk: {
      type: [String],
      enum: ["Sauna", "Vírivka", "Vnútorný bazén", "Vonkajší bazén", "Žiadne"],
    },
  },

  outdoorAmenities: {
    en: {
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
      type: [String],
      enum: ["Free Parking on-site", "Paid Parking on-site", "Public Parking"],
    },
    sk: {
      type: [String],
      enum: ["Bezplatné parkovanie na mieste", "Platené parkovanie", "Verejné parkovanie"],
    },
  },
  checkIn: {
    en: {
      type: [String],
      enum: ["Self Check-in", "Reception", "Host Greeting"],
    },
    sk: {
      type: [String],
      enum: ["Samoobslužný check-in", "Recepcia", "Privítanie hostiteľom"],
    },
  },
  meals: {
    en: {
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
      enum: [
        "Allowed at no extra charge",
        "Allowed with an additional fee",
        "Allowed for a fee by arrangement with the owner",
        "Not Allowed",
      ],
    },
    sk: {
      type: String,
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
      enum: ["Allowed", "Not Allowed"],
    },
    sk: {
      type: String,
      enum: ["Povolené", "Nepovolené"],
    },
  },

  smoking: {
    en: {
      type: String,
      enum: [
        "Allowed indoors",
        "Allowed in designated areas",
        "Not allowed",
      ],
    },
    sk: {
      type: String,
      enum: [
        "Povolené v interiéri",
        "Povolené v určených priestoroch",
        "Nepovolené",
      ],
    },
  },
  images: [
    {
      type: String
    }
  ],
  reviews: [{ type: mongoose.Types.ObjectId, ref: "Review" }],
  averageRating: {
    type: Number,
    default: 0,
  },
  Reservation: [{ type: mongoose.Types.ObjectId, ref: "Reservation" }],
  occupancyCalendar: [
    {
      startDate: {
        type: Date,
        required: false
      },
      endDate: {
        type: Date,
        required: false
      },
      guestName: {
        type: String,
        default: 'N/A'
      },
      status: {
        type: String,
        enum: ['booked', 'available', 'blocked'],
        default: 'booked'
      },
      // Mirror Accommodation.occupancyCalendar's unit fields so a soft-deleted
      // listing keeps which unit each row occupied and restores with it. Unset
      // means the whole listing (manual blocks, imported feeds, and every row
      // on a listing without units), exactly as in the live model.
      unitId: { type: mongoose.Schema.Types.ObjectId, required: false },
      unitName: { type: String, required: false }
    }
  ],
  views: { type: Number, default: 0 },
  clicks: { type: Number, default: 0 },
  customerInterest: { type: Number, default: 0 },
  date: {
    type: Date,
    default: Date.now // Sets the date to the current date/time upon creation
  },
  createdAt: { type: Date, default: Date.now },
  deletedAt: { type: Date, default: Date.now }  // Stores deletion time
}, { timestamps: true });

export default mongoose.model('DeletedAccommodation', DeletedAccommodationSchema);
