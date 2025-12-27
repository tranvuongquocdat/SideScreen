// Tab Virtual Display Website JavaScript

// ==================== Theme Toggle (runs before DOMContentLoaded) ====================
(function() {
    // Check for saved theme preference or default to system preference
    const savedTheme = localStorage.getItem('theme');
    const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;

    if (savedTheme === 'dark' || (!savedTheme && prefersDark)) {
        document.documentElement.setAttribute('data-theme', 'dark');
    }
})();

document.addEventListener('DOMContentLoaded', function() {
    // ==================== Theme Toggle ====================
    const themeToggle = document.getElementById('theme-toggle');

    if (themeToggle) {
        themeToggle.addEventListener('click', () => {
            const currentTheme = document.documentElement.getAttribute('data-theme');
            const newTheme = currentTheme === 'dark' ? 'light' : 'dark';

            if (newTheme === 'dark') {
                document.documentElement.setAttribute('data-theme', 'dark');
            } else {
                document.documentElement.removeAttribute('data-theme');
            }

            localStorage.setItem('theme', newTheme);
        });
    }

    // ==================== Mobile Menu ====================
    const mobileMenuBtn = document.getElementById('mobile-menu-btn');
    const navLinks = document.querySelector('.nav-links');

    if (mobileMenuBtn && navLinks) {
        mobileMenuBtn.addEventListener('click', () => {
            navLinks.classList.toggle('active');
            mobileMenuBtn.setAttribute('aria-expanded',
                navLinks.classList.contains('active'));
        });

        // Close mobile menu when clicking on a link
        document.querySelectorAll('.nav-link').forEach(link => {
            link.addEventListener('click', () => {
                navLinks.classList.remove('active');
            });
        });

        // Close mobile menu when clicking outside
        document.addEventListener('click', (e) => {
            if (!navLinks.contains(e.target) && !mobileMenuBtn.contains(e.target)) {
                navLinks.classList.remove('active');
            }
        });
    }

    // ==================== Smooth Scrolling ====================
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function(e) {
            const targetId = this.getAttribute('href');
            if (targetId === '#') return;

            const targetElement = document.querySelector(targetId);
            if (targetElement) {
                e.preventDefault();
                const headerHeight = document.querySelector('header').offsetHeight;
                const targetPosition = targetElement.offsetTop - headerHeight - 20;

                window.scrollTo({
                    top: targetPosition,
                    behavior: 'smooth'
                });
            }
        });
    });

    // ==================== Scroll Animations ====================
    function animateOnScroll() {
        const elements = document.querySelectorAll(
            '.feature-card, .step, .privacy-feature, .requirement-card, .download-card, .faq-item'
        );

        if ('IntersectionObserver' in window) {
            const observer = new IntersectionObserver((entries) => {
                entries.forEach(entry => {
                    if (entry.isIntersecting) {
                        entry.target.classList.add('animate-in');
                        observer.unobserve(entry.target);
                    }
                });
            }, { threshold: 0.1, rootMargin: '0px 0px -50px 0px' });

            elements.forEach((element, index) => {
                element.style.transitionDelay = `${index * 0.05}s`;
                observer.observe(element);
            });
        } else {
            // Fallback for browsers without IntersectionObserver
            elements.forEach(element => {
                element.classList.add('animate-in');
            });
        }
    }

    animateOnScroll();

    // ==================== Copy to Clipboard ====================
    document.querySelectorAll('.copy-btn').forEach(btn => {
        btn.addEventListener('click', function() {
            const textToCopy = this.getAttribute('data-copy');
            if (textToCopy) {
                navigator.clipboard.writeText(textToCopy).then(() => {
                    // Show feedback
                    const originalHTML = this.innerHTML;
                    this.innerHTML = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="20 6 9 17 4 12"></polyline></svg>';
                    this.classList.add('copied');

                    setTimeout(() => {
                        this.innerHTML = originalHTML;
                        this.classList.remove('copied');
                    }, 2000);
                }).catch(err => {
                    console.error('Failed to copy:', err);
                });
            }
        });
    });

    // ==================== Donation Modal ====================
    const donationModal = document.getElementById('donation-modal');
    const downloadBtns = document.querySelectorAll('.download-btn');
    const closeModalBtn = donationModal?.querySelector('.modal-close');
    const proceedToDownloadBtn = document.getElementById('proceed-to-download');
    let downloadUrl = '';

    const openModal = () => {
        if (donationModal) {
            donationModal.classList.add('active');
            document.body.style.overflow = 'hidden';
        }
    };

    const closeModal = () => {
        if (donationModal) {
            donationModal.classList.remove('active');
            document.body.style.overflow = '';
        }
    };

    // Show modal when clicking download buttons (optional - comment out if not needed)
    downloadBtns.forEach(btn => {
        btn.addEventListener('click', function(e) {
            const href = this.getAttribute('href');
            // Only show modal for actual download links, not anchor links
            if (href && !href.startsWith('#') && donationModal) {
                e.preventDefault();
                downloadUrl = href;
                openModal();
            }
        });
    });

    if (closeModalBtn) {
        closeModalBtn.addEventListener('click', closeModal);
    }

    if (proceedToDownloadBtn) {
        proceedToDownloadBtn.addEventListener('click', function() {
            closeModal();
            if (downloadUrl) {
                window.location.href = downloadUrl;
            }
        });
    }

    if (donationModal) {
        donationModal.addEventListener('click', function(e) {
            if (e.target === this) {
                closeModal();
            }
        });
    }

    // Close modal with Escape key
    document.addEventListener('keydown', function(e) {
        if (e.key === 'Escape' && donationModal?.classList.contains('active')) {
            closeModal();
        }
    });

    // ==================== Header Scroll Effect ====================
    const header = document.getElementById('header');

    window.addEventListener('scroll', () => {
        if (window.pageYOffset > 50) {
            header?.classList.add('scrolled');
        } else {
            header?.classList.remove('scrolled');
        }
    }, { passive: true });

    // ==================== FAQ Accordion ====================
    document.querySelectorAll('.faq-item summary').forEach(summary => {
        summary.addEventListener('click', function() {
            const details = this.parentElement;
            const allDetails = document.querySelectorAll('.faq-item');

            // Close other open FAQs (optional - remove if you want multiple open)
            allDetails.forEach(item => {
                if (item !== details && item.hasAttribute('open')) {
                    item.removeAttribute('open');
                }
            });
        });
    });

    // ==================== Toast Notification ====================
    function createToast(message, type = 'info') {
        const toastContainer = document.querySelector('.toast-container');
        if (!toastContainer) return;

        const toast = document.createElement('div');
        toast.className = `toast toast-${type}`;
        toast.innerHTML = `
            <div class="toast-content">
                <span class="toast-message">${message}</span>
            </div>
            <button class="toast-close" aria-label="Close">&times;</button>
        `;

        toastContainer.appendChild(toast);

        // Show the toast
        setTimeout(() => toast.classList.add('show'), 100);

        // Handle close button
        toast.querySelector('.toast-close').addEventListener('click', () => {
            hideToast(toast);
        });

        // Auto hide after 5 seconds
        setTimeout(() => hideToast(toast), 5000);
    }

    function hideToast(toast) {
        toast.classList.remove('show');
        setTimeout(() => toast.remove(), 300);
    }

    // Make createToast available globally
    window.createToast = createToast;

    // ==================== Contributors Image Lazy Load ====================
    const contributorsImg = document.querySelector('.contributors-img');
    if (contributorsImg) {
        contributorsImg.addEventListener('error', () => {
            // Hide if image fails to load (e.g., repo doesn't exist yet)
            contributorsImg.style.display = 'none';
        });
    }
});
