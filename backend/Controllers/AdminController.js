import mongoose from 'mongoose';
import Admin from '../models/Admin.js';
import Host from '../models/Host.js';
import Accommodation from '../models/Accommodation.js';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import { listPayoutAccounts, payoutStateOf } from '../utils/payoutAccounts.js';
import { DEVELOPER_EMAIL_PATTERNS, TEST_OR_TEAM_EMAIL_PATTERNS } from '../utils/devAccounts.js';
import { applyHostEmailChange, emailProblemCode, normaliseNewEmail } from '../utils/hostEmailChange.js';
import { getTransporter, MAIL_FROM } from '../utils/mailer.js';
import { buildHostEmailChangedNotice } from '../utils/hostEmailChangeEmail.js';

// Register Admin
export const registerAdmin = async (req, res) => {
  try {
    const { email, password, name, phone, photo, gender, role } = req.body;

    // Check if admin already exists
    const existingAdmin = await Admin.findOne({ email });
    if (existingAdmin) {
      return res.status(400).json({ message: 'Admin already exists' });
    }

    // Hash password
    const hashedPassword = await bcrypt.hash(password, 10);

    // Create new admin
    const newAdmin = new Admin({
      email,
      password: hashedPassword,
      name,
      phone,
      photo,
      gender,
      role: role || "superadmin",
    });

    // Save admin to database
    await newAdmin.save();

    // Generate JWT token
    const token = jwt.sign(
      { adminId: newAdmin._id, role: newAdmin.role }, // Include role in token
      process.env.JWT_SECRET_KEY,
      { expiresIn: "1h" }
    );

    res.status(200).json({ status:"true", message: "Admin registered successfully", token, admin: newAdmin });
  } catch (error) {
    console.error(  'Error registering admin:', error.message); // Log the exact error
    res.status(500).json({ message: 'Error registering admin' });
  }
};
// Login Admin
export const loginAdmin = async (req, res) => {
  try {
    const { email, password } = req.body;

    // Find admin by email
    const admin = await Admin.findOne({ email });
    if (!admin) {
      return res.status(401).json({ message: 'Invalid email or password' });
    }

    // Compare passwords
    const isMatch = await bcrypt.compare(password, admin.password);
    if (!isMatch) {
      return res.status(401).json({ message: 'Invalid email or password' });
    }

    // Generate JWT token with role
    const token = jwt.sign(
      { adminId: admin._id, role: admin.role }, // Include role
      process.env.JWT_SECRET_KEY,
      { expiresIn: "1h" }
    );

    res.status(200).json({ token, admin });
  } catch (error) {
    res.status(500).json({ message: 'Error logging in admin' });
  }
};

// Get All Admins
export const getAllAdmins = async (req, res) => {
  try {
    const admins = await Admin.find().select('-password');
    res.status(200).json(admins);
  } catch (error) {
    res.status(500).json({ message: 'Error getting admins' });
  }
};

// Get Admin by ID
export const getAdminById = async (req, res) => {
  try {
    const adminId = req.params.adminId;
    const admin = await Admin.findById(adminId).select('-password');
    if (!admin) {
      return res.status(404).json({ message: 'Admin not found' });
    }
    res.status(200).json(admin);
  } catch (error) {
    res.status(500).json({ message: 'Error getting admin' });
  }
};

// Update Admin
export const updateAdmin = async (req, res) => {
  try {
    const adminId = req.params.adminId;
    const { name, phone, photo, gender } = req.body;

    const admin = await Admin.findById(adminId);
    if (!admin) {
      return res.status(404).json({ message: 'Admin not found' });
    }

    admin.name = name;
    admin.phone = phone;
    admin.photo = photo;
    admin.gender = gender;

    await admin.save();

    res.status(200).json(admin);
  } catch (error) {
    res.status(500).json({ message: 'Error updating admin' });
  }
};

// Get hosts who have connected a Stripe account, with each one's name, email
// and status (verified | verifying | pending | restricted) on their default
// payout account — derived via the same rule the booking gate uses, so this
// never disagrees with what actually decides whether a host gets paid.
export const getStripeConnectedHostsCount = async (req, res) => {
  try {
    // Only hosts that own at least one listing count, so every figure below
    // is about the same population.
    const listingHostIds = await Accommodation.distinct('userId');
    const testHosts = await Host.find({ email: { $in: TEST_OR_TEAM_EMAIL_PATTERNS } }).select('_id').lean();
    const totalListings = await Accommodation.countDocuments({
      userId: { $nin: testHosts.map((h) => h._id) },
    });
    const totalHosts = await Host.countDocuments({
      _id: { $in: listingHostIds },
      email: { $nin: TEST_OR_TEAM_EMAIL_PATTERNS },
    });

    const connectedHosts = await Host.find({
      _id: { $in: listingHostIds },
      stripeAccountId: { $exists: true, $ne: null, $ne: '' },
      email: { $nin: TEST_OR_TEAM_EMAIL_PATTERNS },
    }).select(
      'name email stripeAccountId stripeAccounts payoutsEnabled chargesEnabled ' +
      'stripeTransfersActive stripePayoutState stripeDisabledReason stripePastDue ' +
      'stripeRequirementsDue'
    );

    const accommodations = await Accommodation.find({
      userId: { $in: connectedHosts.map((host) => host._id) },
    })
      .select('userId name slug')
      .lean();
    const accommodationsByHost = new Map();
    const siteUrl = (process.env.CLIENT_SITE_URL || 'https://ukstayhub.co.uk').replace(/\/+$/, '');

    for (const accommodation of accommodations) {
      const hostId = String(accommodation.userId);
      const hostAccommodations = accommodationsByHost.get(hostId) || [];
      hostAccommodations.push({
        id: accommodation._id,
        name: accommodation.name,
        slug: accommodation.slug,
        url: `${siteUrl}/listings/${encodeURIComponent(accommodation.slug)}`,
      });
      accommodationsByHost.set(hostId, hostAccommodations);
    }

    const hosts = connectedHosts.map((host) => {
      const defaultAccount = listPayoutAccounts(host).find((a) => a.isDefault);
      const state = payoutStateOf(defaultAccount);
      return {
        id: host._id,
        name: host.name,
        email: host.email,
        stripeAccountId: host.stripeAccountId,
        accommodations: accommodationsByHost.get(String(host._id)) || [],
        // "verified" is a friendlier label for the "active" state than what
        // Stripe/the schema call it; pending/verifying/restricted pass through.
        status: state === 'active' ? 'verified' : state,
      };
    });

    const payoutReady = hosts.filter((h) => h.status === 'verified').length;

    res.status(200).json({
      totalListings,
      totalHosts,
      connected: hosts.length,
      notConnected: totalHosts - hosts.length,
      payoutReady,
      hosts,
    });
  } catch (error) {
    res.status(500).json({ message: 'Error getting Stripe connected hosts' });
  }
};

// Genuine vs test/team split. "Test/team" = hosts whose email is in
// DEVELOPER_EMAILS or Team_emails; their listings are the test listings.
export const getGenuineVsTestCounts = async (_req, res) => {
  try {
    const [testHosts, listings] = await Promise.all([
      Host.find({ email: { $in: TEST_OR_TEAM_EMAIL_PATTERNS } }).select('_id').lean(),
      Accommodation.find().select('userId').lean(),
    ]);
    const testIds = new Set(testHosts.map((h) => String(h._id)));
    const hostIds = new Set(listings.map((l) => String(l.userId)));
    const testListings = listings.filter((l) => testIds.has(String(l.userId))).length;
    const testHostCount = [...hostIds].filter((id) => testIds.has(id)).length;
    return res.status(200).json({
      totalListings: listings.length,
      genuineListings: listings.length - testListings,
      testListings,
      totalHosts: hostIds.size,
      genuineHosts: hostIds.size - testHostCount,
      testOrTeamHosts: testHostCount,
    });
  } catch (error) {
    return res.status(500).json({ message: 'Error getting genuine vs test counts' });
  }
};

// Keep city membership aligned with frontend/src/app/utils/tourismRegions.js.
const ADMIN_TOURISM_REGIONS = [
  { id: 'liptov', name: 'Liptov', cities: ['Demänovská Dolina','Liptovský Mikuláš','Liptovský Trnovec','Liptovský Ján','Bešeňová','Ružomberok','Liptovská Sielnica','Liptovské Revúce','Liptovský Hrádok','Liptovská Kokava','Liptovská Osada','Liptovské Sliače','Liptovské Sliace','Žiar (okres Liptovský Mikuláš)','Liptovská Anna','Dúbrava (okres Liptovský Mikuláš)','Jakubovany (okres Liptovský Mikuláš)','Konská (okres Liptovský Mikuláš)','Kvačany (okres Liptovský Mikuláš)','Kvacany (okres Liptovský Mikuláš)','Liptovská Teplá','Lúčky (okres Ružomberok)','Lúcky (okres Ružomberok)','Liptovská Porúbka','Liptovské Matiašovce','Liptovský Michal'] },
  { id: 'vysoke-tatry', name: 'Vysoké Tatry', cities: ['Vysoké Tatry','Ždiar','Stará Lesná','Poprad','Štrba','Nová Lesná','Kežmarok','Veľká Lomnica','Vrbov','Veľký Slavkov','Tatranská Lomnica','Mengusovce','Štôla','Batizovce'] },
  { id: 'slovensky-raj', name: 'Slovenský raj', cities: ['Hrabušice','Smižany','Spišská Nová Ves','Dedinky','Mlynky','Stratená','Betlanovce','Letanovce','Spišské Tomášovce','Vernár'] },
  { id: 'orava', name: 'Orava', cities: ['Dolný Kubín','Námestovo','Tvrdošín','Zuberec','Habovka','Oravská Lesná','Oravský Podzámok','Trstená','Bobrov','Oravská Polhora','Vitanová','Podbiel'] },
  { id: 'horehronie', name: 'Horehronie', cities: ['Brezno','Mýto pod Ďumbierom','Tále','Bystrá','Horná Lehota','Donovaly','Čierny Balog','Heľpa','Telgárt','Závadka nad Hronom'] },
  { id: 'pieniny', name: 'Pieniny', cities: ['Červený Kláštor','Lesnica','Spišská Stará Ves','Jezersko','Veľký Lipník','Haligovce','Majere'] },
  { id: 'mala-fatra', name: 'Malá Fatra', cities: ['Terchová','Zázrivá','Vrátna','Varín','Belá','Štefanová'] },
  { id: 'banska-stiavnica', name: 'Banská Štiavnica a okolie', cities: ['Banská Štiavnica','Hodruša-Hámre','Štiavnické Bane','Vyhne','Sklené Teplice','Svätý Anton'] },
];
const adminCityKey = (value) => String(value || '').normalize('NFD')
  .replace(/\p{Diacritic}/gu, '').toLocaleLowerCase('sk').trim().replace(/\s+/g, ' ');
const adminRegionByCity = new Map(ADMIN_TOURISM_REGIONS.flatMap((region) =>
  region.cities.map((city) => [adminCityKey(city), region])
));
const adminRegionForListing = (listing) => {
  const region = adminRegionByCity.get(adminCityKey(listing.locationDetails?.city));
  if (region) return region;
  const state = String(listing.locationDetails?.state || '').trim();
  if (state) return { id: `location-${adminCityKey(state).replace(/\s+/g, '-')}`, name: state };
  return { id: 'other', name: 'Other' };
};

export const getListingCountsByRegion = async (_req, res) => {
  try {
    const listings = await Accommodation.find().select('locationDetails.city locationDetails.state').lean();
    const counts = new Map();
    for (const listing of listings) {
      const region = adminRegionForListing(listing);
      const count = counts.get(region.id) || { regionId: region.id, region: region.name, listings: 0 };
      count.listings += 1;
      counts.set(region.id, count);
    }
    const regions = [...counts.values()].sort((a, b) => b.listings - a.listings || a.region.localeCompare(b.region));
    return res.status(200).json({
      totalListings: listings.length,
      mostListingsRegion: regions[0] || null,
      regions,
    });
  } catch (error) {
    return res.status(500).json({ message: 'Error getting listing counts by region' });
  }
};

export const getHostPayoutReadinessByRegion = async (_req, res) => {
  try {
    const [hosts, listings] = await Promise.all([
      Host.find({ email: { $nin: DEVELOPER_EMAIL_PATTERNS } }).select(
        'stripeAccountId stripeAccounts payoutsEnabled chargesEnabled stripeTransfersActive stripePayoutState stripeDisabledReason stripePastDue stripeRequirementsDue'
      ).lean(),
      Accommodation.find().select('userId locationDetails.city locationDetails.state locationDetails.country').lean(),
    ]);
    const hostsById = new Map(hosts.map((host) => [String(host._id), host]));
    const byRegion = new Map();
    for (const listing of listings) {
      const host = hostsById.get(String(listing.userId));
      if (!host) continue;
      const region = adminRegionForListing(listing);
      if (!byRegion.has(region.id)) byRegion.set(region.id, {
        regionId: region.id,
        region: region.name,
        hosts: new Map(),
        locations: new Map(),
      });
      const regionEntry = byRegion.get(region.id);
      const regionHosts = regionEntry.hosts;
      const hostId = String(host._id);
      const account = listPayoutAccounts(host).find((item) => item.isDefault);
      const connected = Boolean(account);
      const payoutReady = connected && payoutStateOf(account) === 'active';
      if (!regionHosts.has(hostId)) regionHosts.set(hostId, {
        connected,
        payoutReady,
      });

      if (region.id === 'other') {
        const city = String(listing.locationDetails?.city || '').trim() || 'Unknown';
        const state = String(listing.locationDetails?.state || '').trim() || 'Unknown';
        const country = String(listing.locationDetails?.country || '').trim() || 'Unknown';
        const key = `${state}\u0000${city}\u0000${country}`;
        if (!regionEntry.locations.has(key)) {
          regionEntry.locations.set(key, { state, city, country, hosts: new Map() });
        }
        const locationHosts = regionEntry.locations.get(key).hosts;
        if (!locationHosts.has(hostId)) locationHosts.set(hostId, { connected, payoutReady });
      }
    }
    const regions = [...byRegion.values()].map(({ regionId, region, hosts: regionHosts, locations }) => {
      const entries = [...regionHosts.values()];
      const connected = entries.filter((host) => host.connected).length;
      const locationBreakdown = [...locations.values()].map(({ state, city, country, hosts: locationHosts }) => {
        const locationEntries = [...locationHosts.values()];
        const locationConnected = locationEntries.filter((host) => host.connected).length;
        return {
          state,
          city,
          country,
          totalHosts: locationEntries.length,
          connected: locationConnected,
          notConnected: locationEntries.length - locationConnected,
          payoutReady: locationEntries.filter((host) => host.payoutReady).length,
        };
      }).sort((a, b) => b.totalHosts - a.totalHosts || a.city.localeCompare(b.city));
      return {
        regionId,
        region,
        totalHosts: entries.length,
        connected,
        notConnected: entries.length - connected,
        payoutReady: entries.filter((host) => host.payoutReady).length,
        ...(regionId === 'other' ? { locations: locationBreakdown } : {}),
      };
    }).sort((a, b) => b.totalHosts - a.totalHosts || a.region.localeCompare(b.region));
    const overall = hosts.map((host) => {
      const account = listPayoutAccounts(host).find((item) => item.isDefault);
      const connected = Boolean(account);
      return {
        connected,
        payoutReady: connected && payoutStateOf(account) === 'active',
      };
    });
    const connected = overall.filter((host) => host.connected).length;
    return res.status(200).json({
      totalHosts: overall.length,
      connected,
      notConnected: overall.length - connected,
      payoutReady: overall.filter((host) => host.payoutReady).length,
      regions,
    });
  } catch (error) {
    return res.status(500).json({ message: 'Error getting host payout readiness by region' });
  }
};

// Delete Admin
export const deleteAdmin = async (req, res) => {
  try {
    const adminId = req.params.adminId;
    await Admin.findByIdAndDelete(adminId);
    res.status(200).json({ message: 'Admin deleted successfully' });
  } catch (error) {
    res.status(500).json({ message: 'Error deleting admin' });
  }
};

// PATCH /api/admin/hosts/:hostId/email  (requireAdmin)
//
// An admin vouches for the new address, so there is no password or code step
// (the host may be locked out of their old mailbox, which is the usual reason).
// Everything else is the same as the host's own flow: uniqueness against hosts
// AND travellers, the linked traveller account and unsent invoices move with it,
// and both addresses are told.
export const changeHostEmailByAdmin = async (req, res) => {
  try {
    if (!mongoose.Types.ObjectId.isValid(req.params.hostId)) {
      return res.status(400).json({ message: "Invalid host id." });
    }
    const host = await Host.findById(req.params.hostId);
    if (!host) return res.status(404).json({ message: "Host not found." });

    const newEmail = normaliseNewEmail(req.body?.newEmail);
    const problem = await emailProblemCode(host, newEmail);
    if (problem) {
      const message = {
        invalid: "Enter a valid email address.",
        same: "That is already this host's email address.",
        taken: "This email address is already used by another account.",
      }[problem];
      return res.status(problem === "taken" ? 409 : 400).json({ message });
    }

    const oldEmail = await applyHostEmailChange(host, newEmail);
    console.log(`[putko-audit] host.email.changed.by-admin host=${host._id} admin=${req.auth?.id} at=${new Date().toISOString()}`);

    // Best effort: the change has already happened.
    const notice = buildHostEmailChangedNotice({ newEmail, lang: req.body?.lang });
    for (const to of [oldEmail, newEmail]) {
      try {
        await getTransporter().sendMail({ from: MAIL_FROM, to, ...notice });
      } catch (mailError) {
        console.error(`host email change: could not notify ${to}:`, mailError.message);
      }
    }

    res.status(200).json({ message: "Email updated.", host: { _id: host._id, email: host.email } });
  } catch (error) {
    if (error?.code === 11000) return res.status(409).json({ message: "This email address is already used by another account." });
    console.error("Error in changeHostEmailByAdmin controller:", error.message);
    res.status(500).json({ message: "Could not change the email." });
  }
};
