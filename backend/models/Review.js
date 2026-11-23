import mongoose from 'mongoose';
import Accommodation from './Accommodation.js';

const reviewSchema = new mongoose.Schema({
  accommodation: {
    type: mongoose.Types.ObjectId,
    ref: 'Accommodation',
    required: true,
  },

  name: {
      type: String,
      required: true,
      index: true
    },
  email: {
    type: String,
    required: false,
  },
  reviewText: {   // ✅ added field
    type: String,
    required: true,
    index: true
  },
  pluses: String,
  cons: String,
  overallRating: {
    type: Number,
    required: true,
    min: 1,
    max: 5,
    default: 0,
  },
  categoryRatings: {
    Location: { type: Number, min: 0, max: 5, default: 0 },
    Communication: { type: Number, min: 0, max: 5, default: 0 },
    Equipment: { type: Number, min: 0, max: 5, default: 0 },
    Cleanliness: { type: Number, min: 0, max: 5, default: 0 },
    ClientCare: { type: Number, min: 0, max: 5, default: 0 },
    WiFi: { type: Number, min: 0, max: 5, default: 0 },
    Activities: { type: Number, min: 0, max: 5, default: 0 },
    PriceQuality: { type: Number, min: 0, max: 5, default: 0 },
  },
}, { timestamps: true });

/**
 * Score for ONE review, as an aggregation expression: the mean of the category
 * stars it actually awarded, falling back to its own `overallRating`, and null
 * when it carries no usable stars at all (so it can be filtered out rather than
 * counted as zero).
 *
 * Exported so utils/recalcAverageRatings.js scores existing reviews exactly the
 * way new ones are scored — the backfill and the live hook must not drift.
 */
export const reviewScoreExpression = {
  $let: {
    vars: {
      // Zero is the schema default and means "not rated", so it is not a score
      // of zero and must not drag the average down.
      given: {
        $filter: {
          input: { $objectToArray: { $ifNull: ['$categoryRatings', {}] } },
          as: 'c',
          cond: { $gt: ['$$c.v', 0] },
        },
      },
    },
    in: {
      $cond: [
        { $gt: [{ $size: '$$given' }, 0] },
        { $avg: { $map: { input: '$$given', as: 'g', in: '$$g.v' } } },
        { $cond: [{ $gt: ['$overallRating', 0] }, '$overallRating', null] },
      ],
    },
  },
};

// Static method to calculate average ratings for an accommodation.
//
// This mirrors listingRatingFromReviews() in frontend/src/app/utlis/rating.js —
// the two MUST stay in step, or the stored figure on listing cards drifts from
// the one the listing page computes from the same reviews, which is the bug
// this replaced.
//
// A review is scored from the category stars it actually awarded, because those
// are what the listing page displays. `overallRating` is a SEPARATE star row on
// the review form, unrelated to the category scores, so averaging it produced a
// headline that contradicted every category bar beneath it.
//
// The fallback to `overallRating` is per review, not per listing: reviews
// imported from other platforms (utils/importHost.js) only ever set
// `overallRating` and get all-zero category defaults from the schema, and a
// listing commonly holds a mix of imported and native reviews. Falling back per
// listing would drop every imported review as soon as one native review existed.
reviewSchema.statics.calAverageRatings = async function(accommodationId) {
  const stats = await this.aggregate([
    { $match: { accommodation: accommodationId } },
    { $project: { accommodation: 1, score: reviewScoreExpression } },
    // Reviews carrying no usable stars at all must not count as zero.
    { $match: { score: { $ne: null } } },
    { $group: {
        _id: '$accommodation',
        numOfRatings: { $sum: 1 },
        avgRating: { $avg: '$score' },
      },
    },
  ]);

  if (stats.length > 0) {
    await Accommodation.findByIdAndUpdate(accommodationId, {
      averageRating: stats[0].avgRating,
    });
  } else {
    await Accommodation.findByIdAndUpdate(accommodationId, {
      averageRating: 0,
    });
  }
};

// Every listing card and page resolves its reviews by accommodation (the
// `reviewDocs` populate, calAverageRatings). Without this index each of those
// lookups scanned the whole collection — ~12 s for one region's cards, which
// pushed the /ubytovanie region pages past Vercel's function time limit.
reviewSchema.index({ accommodation: 1 });

// Post-hook to recalculate average ratings after saving a review
reviewSchema.post('save', function() {
  this.constructor.calAverageRatings(this.accommodation);
});

// ✅ Also handle when a review is deleted
reviewSchema.post('findOneAndDelete', async function (doc) {
  if (doc) await doc.constructor.calAverageRatings(doc.accommodation);
});

export default mongoose.model('Review', reviewSchema);
