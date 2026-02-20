// Side Screen Website JavaScript

// ==================== Theme Toggle (runs early to prevent flash) ====================
(function() {
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

        document.querySelectorAll('.nav-link').forEach(link => {
            link.addEventListener('click', () => {
                navLinks.classList.remove('active');
            });
        });

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
            '.special-feature-item, .step, .download-card, .faq-item'
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
            elements.forEach(element => {
                element.classList.add('animate-in');
            });
        }
    }

    animateOnScroll();

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

    downloadBtns.forEach(btn => {
        btn.addEventListener('click', function(e) {
            const href = this.getAttribute('href');
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
        setTimeout(() => toast.classList.add('show'), 100);

        toast.querySelector('.toast-close').addEventListener('click', () => {
            hideToast(toast);
        });

        setTimeout(() => hideToast(toast), 5000);
    }

    function hideToast(toast) {
        toast.classList.remove('show');
        setTimeout(() => toast.remove(), 300);
    }

    window.createToast = createToast;
});
