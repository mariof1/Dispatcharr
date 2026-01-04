from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("m3u", "0018_add_profile_custom_properties"),
    ]

    operations = [
        migrations.AddField(
            model_name="m3uaccount",
            name="refresh_time",
            field=models.CharField(blank=True, max_length=5, null=True),
        ),
    ]
