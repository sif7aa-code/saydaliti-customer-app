const fs = require('fs');
const dir = 'M:/strasopa/shatra_hosting/public/';
const policy = fs.readFileSync('M:/strasopa/shatra_hosting/bp_policy.html', 'utf8');
const about = fs.readFileSync('M:/strasopa/shatra_hosting/bp_about.html', 'utf8');

const B_URL = 'https://shatra-center.blogspot.com/p/blog-page.html';
const A_URL = 'https://shatra-center.blogspot.com/p/blog-page_23.html';
const HOME = 'https://shatra-center.blogspot.com/';

const CSS = `
*{box-sizing:border-box}
body{margin:0;background:#F4F6F2;color:#1B2A24;font-family:'Cairo','Segoe UI',Tahoma,sans-serif;line-height:1.9}
.wrap{max-width:840px;margin:0 auto;padding:28px 20px 60px}
header{padding:26px 0 18px;border-bottom:2px solid #E2E7E2;margin-bottom:26px}
.brand{font-size:30px;font-weight:800;color:#1F7A5C;margin:0}
.tag{color:#5A6B62;font-size:16px;margin:6px 0 0}
nav{display:flex;flex-wrap:wrap;gap:10px;margin-top:18px}
nav a{background:#FFFFFF;color:#1F7A5C;text-decoration:none;font-weight:700;font-size:15px;padding:9px 16px;border:1px solid #DCE3DC;border-radius:8px}
nav a:hover{background:#EAF3EE}
article h2{color:#1F7A5C;font-size:26px;margin:8px 0 14px}
article h3{color:#15593F;font-size:21px;margin:28px 0 8px}
article p{margin:10px 0}
article ul{margin:8px 0;padding-inline-start:22px}
article li{margin:9px 0}
.note{background:#FFFFFF;border:1px solid #DCE3DC;border-radius:10px;padding:16px 18px;margin:22px 0;font-size:15px}
.note b{color:#1F7A5C}
footer{margin-top:44px;padding-top:20px;border-top:2px solid #E2E7E2;font-size:15px;color:#4A5A51}
footer a{color:#1F7A5C;font-weight:700;text-decoration:none;word-break:break-all}
.en{direction:ltr;text-align:left;font-family:Arial,Helvetica,sans-serif}
`;

function shell(o) {
  return `<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="index,follow">
<title>${o.title}</title>
<meta name="description" content="${o.desc}">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Cairo:wght@400;700;800&display=swap" rel="stylesheet">
<style>${CSS}</style>
</head>
<body>
<div class="wrap">
<header>
<p class="brand">سنتر الشطرة</p>
<p class="tag">${o.tag}</p>
<nav><a href="/index.html">الرئيسية</a><a href="/about.html">عن التطبيق</a><a href="/privacy.html">سياسة الخصوصية</a></nav>
</header>
${o.body}
<footer>
<p>الجهة المالكة: منصة الشطرة — البريد الإلكتروني للتواصل: <a href="mailto:mnstalshtrt@gmail.com">mnstalshtrt@gmail.com</a></p>
<p>النسخة الكاملة المنشورة على بلوجر: <a href="${B_URL}">${B_URL}</a></p>
<p>صفحة «عن تطبيق سنتر الشطرة»: <a href="${A_URL}">${A_URL}</a></p>
<p>مدونة بلوجر: <a href="${HOME}">${HOME}</a></p>
</footer>
</div>
</body>
</html>
`;
}

const bl = `<div class="note">هذه الصفحة منشورة أيضاً على مدونة بلوجر الرسمية للتطبيق، ونسخة بلوجر هي النص الكامل المرجعي: <a href="${B_URL}" target="_blank" rel="noopener">سياسة الخصوصية على بلوجر</a> — وصفحة <a href="${A_URL}" target="_blank" rel="noopener">عن التطبيق</a>.</div>`;

fs.writeFileSync(dir + 'privacy.html', shell({
  title: 'سياسة الخصوصية — تطبيق سنتر الشطرة',
  desc: 'سياسة الخصوصية الرسمية لتطبيق سنتر الشطرة (com.shatra.shtrapp): البيانات التي نجمعها وكيف نستخدمها ولمن نشاركها.',
  tag: 'سياسة الخصوصية الرسمية للتطبيق',
  body: '<article>' + policy + '</article>' + bl,
}));

fs.writeFileSync(dir + 'about.html', shell({
  title: 'عن تطبيق سنتر الشطرة',
  desc: 'تعريف بتطبيق سنتر الشطرة: سوق إلكتروني لمتاجر مدينة الشطرة، وأنواع الحسابات وطريقة تسجيل الدخول.',
  tag: 'تعريف بتطبيق سنتر الشطرة',
  body: '<article>' + about + '</article>' + bl,
}));

fs.writeFileSync(dir + 'index.html', shell({
  title: 'سنتر الشطرة — الموقع الرسمي للتطبيق',
  desc: 'الموقع الرسمي والدعم لتطبيق سنتر الشطرة: سياسة الخصوصية، وعن التطبيق، وطرق التواصل.',
  tag: 'الموقع الرسمي والدعم لتطبيق سنتر الشطرة',
  body: `<article>
<h2>مرحباً بك في موقع سنتر الشطرة</h2>
<p>تطبيق <b>سنتر الشطرة</b> (اسم الحزمة: com.shatra.shtrapp) هو سوق إلكتروني يجمع متاجر مدينة الشطرة ومنطقتها في مكان واحد: يتصفّح الزبون المنتجات ويطلبها، ويوصلها مندوب مسجّل داخل التطبيق.</p>
<h3>روابط مهمة</h3>
<ul>
<li><a href="/privacy.html">سياسة الخصوصية (هذه الاستضافة)</a></li>
<li><a href="/about.html">عن التطبيق وإمكانياته</a></li>
<li><a href="${B_URL}" target="_blank" rel="noopener">سياسة الخصوصية على بلوجر</a></li>
<li><a href="${A_URL}" target="_blank" rel="noopener">صفحة «عن تطبيق سنتر الشطرة» على بلوجر</a></li>
<li><a href="${HOME}" target="_blank" rel="noopener">مدونة بلوجر الرسمية</a></li>
</ul>
<h3>التواصل والدعم</h3>
<p>لأي استفسار عن الخصوصية أو حذف الحساب أو المشاكل التقنية راسلنا على: <a href="mailto:mnstalshtrt@gmail.com">mnstalshtrt@gmail.com</a></p>
<h3>English</h3>
<p class="en">This is the official support website for the <b>Shatra Center</b> Android app (com.shatra.shtrapp), a local online marketplace for shops in Shatra, Iraq. It explains what the app does and publishes its privacy policy. Privacy policy: <a href="/privacy.html">/privacy.html</a> — About the app: <a href="/about.html">/about.html</a> — Contact: <a href="mailto:mnstalshtrt@gmail.com">mnstalshtrt@gmail.com</a>.</p>
</article>
<div class="note en">Privacy policy is published in full on this host and on Blogger: <a href="${B_URL}">${B_URL}</a></div>`,
}));

fs.writeFileSync(dir + 'robots.txt', 'User-agent: *\nAllow: /\n');

for (const f of ['index.html', 'about.html', 'privacy.html', 'robots.txt']) {
  console.log(f, fs.statSync(dir + f).size);
}
