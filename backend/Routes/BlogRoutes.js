import express from 'express';
import { createBlog, getBlogs, getBlogById, deleteBlog, editBlog, getBlogBySlug, incrementView, getBlogSitemap, getDeletedBlogs, restoreBlog, deleteAllBlogs, restoreAllBlogs, deleteBlogPermanently } from '../Controllers/BlogController.js';
import { requireAdmin } from '../auth/authorize.js';

const router = express.Router();

// Creating, editing and deleting posts is admin-only. These three routes used
// to be open, so anyone who knew the API address could rewrite or delete
// every post on the site.

// Route for creating a new blog post
router.post('/', requireAdmin, createBlog);

// Route for fetching all blog posts
router.get('/', getBlogs);

// NEW SITEMAP ROUTE
router.get("/sitemap", getBlogSitemap);

// Get a blog by Slug (SEO friendly)
router.get('/slug/:slug', getBlogBySlug);

// Deleted blogs (admin-only). Must stay above '/:id' routes.
router.get('/deleted', requireAdmin, getDeletedBlogs);
router.put('/restore-all', requireAdmin, restoreAllBlogs);
router.put('/restore/:id', requireAdmin, restoreBlog);
router.delete('/', requireAdmin, deleteAllBlogs);
router.delete('/deleted/:id', requireAdmin, deleteBlogPermanently);

// Route for fetching a single blog post by ID
router.get('/:id', getBlogById);

// Increment view count
router.post("/:id/view", incrementView);

// Route for deleting a blog post by ID
router.delete('/:id', requireAdmin, deleteBlog);

// Route for editing a blog post by ID
router.put('/:id', requireAdmin, editBlog);

export default router;
