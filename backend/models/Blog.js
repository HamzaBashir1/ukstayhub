import mongoose from 'mongoose';
import { slugify } from '../utils/slugify.js';
import { contentUpdatedAtPlugin, BLOG_CONTENT_FIELDS } from '../utils/contentUpdatedAt.js';

const blogSchema = new mongoose.Schema({
  title: { type: String, required: true, index: true },
  slug: { type: String, required: true, unique: true, index: true },
  content: { type: String, required: true, index: true },
  author: { type: String, default: 'Admin', index: true },
  authorName: { type: String, index: true }, // Explicit author name
  authorImg: { type: String, index: true }, // Added field for author image
  categories: { type: String, required: true, index: true },
  tags: { type: [String], default: [], index: true },
  image: { type: String, index: true },
  summary: { type: String, required: true, index: true },
  blogType: {
    type: String,
    enum: ['customer', 'provider'],
    required: true,
    index: true
  },
  views: { type: Number, default: 0, index: true },
  createdAt: { type: Date, default: Date.now, index: true }
});

// Sitemap lastmod: moves only when something shown on the post changes. (Blog
// has no `updatedAt`, so edits used to leave lastmod at the creation date.)
blogSchema.plugin(contentUpdatedAtPlugin, { fields: BLOG_CONTENT_FIELDS });

// Virtual field to format created date
blogSchema.virtual('formattedDate').get(function () {
  return new Date(this.createdAt).toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric'
  });
});

// Title → slug. Uses the shared slugify so accented letters are
// transliterated ("Prečo" → "preco") instead of deleted ("preo").
const createSlug = (text) => slugify(text);

// Pre-save hook for slug creation
blogSchema.pre('validate', async function (next) {
  // Only (re)build the slug for a new post or a changed title. Rebuilding it on
  // every save would move an existing post to a new URL just because it was
  // edited, breaking every link to it.
  if (this.title && (this.isNew || !this.slug || this.isModified('title'))) {
    let generatedSlug = createSlug(this.title);

    // Ensure uniqueness by appending a counter if needed
    let slugExists = await mongoose.models.Blog.findOne({ slug: generatedSlug });
    let counter = 1;
    while (slugExists && slugExists._id.toString() !== this._id.toString()) {
      generatedSlug = `${createSlug(this.title)}-${counter}`;
      slugExists = await mongoose.models.Blog.findOne({ slug: generatedSlug });
      counter++;
    }

    this.slug = generatedSlug;
  }
  next();
});

export default mongoose.model('Blog', blogSchema);
