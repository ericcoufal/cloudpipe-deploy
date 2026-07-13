// The JS file that once got "forgotten" in a manual deploy and broke
// the contact form. With `aws s3 sync`, it ships with every deploy.

document.getElementById('contact-form').addEventListener('submit', (e) => {
  e.preventDefault();
  const status = document.getElementById('form-status');
  status.hidden = false;
  status.textContent = 'Thanks! We\'ll get back to you soon. (Demo form, no backend wired up.)';
  e.target.reset();
});
