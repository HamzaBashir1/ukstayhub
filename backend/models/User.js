import mongoose from "mongoose";

const UserSchema = new mongoose.Schema(
  {
    email: { type: String, required: true, unique: true },
    password: { type: String, required: false },
    name: { type: String, required: true },
    lastName: { type: String },
    phone: { type: String }, // Changed from Number to String
    photo: { type: String },
    // Preferred UI language. Registration and the guest account screen both
    // send it; without the field mongoose dropped it silently.
    language: {
      type: String,
      enum: ["Slovak", "English"],
      default: "English",
    },
    role: {
      type: String,
      enum: ["guest", "admin"],
      default: "guest",
    },
    gender: {
      type: String,
      enum: ["male", "female", "other"],
      default: "other",
    },
    dateOfBirth: {
      type: Date,
      required: false,
    },
    address: {
        type: String,
        required: false,
    },
    aboutYou: {
        type: String,
        required: false,
    },
    // Address information
    streetNumber: { type: String },
    city: { type: String },
    zipcode: { type: String },
    country: { type: String },
    // Identification information
    idNumber: { type: String },  // National ID or similar
    tin: { type: String },  // Tax Identification Number
    vatNumber: { type: String },  
    companyName: { type: String },  // VAT number for companies
    phoneNumber: { type: String },  // Alternative phone number
    favorites: [{
      type: mongoose.Schema.Types.ObjectId,
      ref: 'Accommodation',
  }],
  // Reset Password Fields
  resetPasswordToken: { type: String },
  resetPasswordExpires: { type: Date },
  isVerified: { type: Boolean, default: false },
  // Email verification code (hashed). See utils/emailVerificationCode.js.
  emailVerificationCode: { type: String, select: false },
  emailVerificationExpires: { type: Date, select: false },
  emailVerificationAttempts: { type: Number, default: 0, select: false },
  emailVerificationSentAt: { type: Date, select: false },
  // Set on accounts created automatically for a guest who booked without
  // signing up: their password was emailed to them, so it is a one-time key to
  // get in and choose a real one, not a credential to keep.
  mustChangePassword: { type: Boolean, default: false },
  },
  { timestamps: true } // Automatically add createdAt and updatedAt fields
);

export default mongoose.model("User", UserSchema);
