(function () {
	const saved = localStorage.getItem('theme');
	if (saved) document.documentElement.setAttribute('data-theme', saved);

	document.addEventListener('DOMContentLoaded', function () {
		updateThemeButton();
	});
})();

function currentTheme() {
	return document.documentElement.getAttribute('data-theme') || 'dark';
}

function updateThemeButton() {
	const btn = document.querySelector('.theme-toggle');
	if (btn) btn.textContent = currentTheme();
}

function toggleNav() {
	document.querySelector('.nav-links').classList.toggle('open');
}

function toggleTheme() {
	const next = currentTheme() === 'light' ? 'dark' : 'light';
	document.documentElement.setAttribute('data-theme', next);
	localStorage.setItem('theme', next);
	updateThemeButton();
}
