import mongoose from 'mongoose';

// Soft-deleted blog posts. Mirrors Blog (without its hooks/plugins) so a post
// can be restored exactly as it was.
const DeletedBlogSchema = new mongoose.Schema({
  title: { type: String, required: true },
  slug: { type: String, required: true },
  content: { type: String, required: true },
  author: { type: String, default: 'Admin' },
  authorName: { type: String },
  authorImg: { type: String },
  categories: { type: String, required: true },
  tags: { type: [String], default: [] },
  image: { type: String },
  summary: { type: String, required: true },
  blogType: { type: String, enum: ['customer', 'provider'], required: true },
  views: { type: Number, default: 0 },
  contentUpdatedAt: { type: Date },
  createdAt: { type: Date, default: Date.now },
  deletedAt: { type: Date, default: Date.now }
});

export default mongoose.model('DeletedBlog', DeletedBlogSchema);
