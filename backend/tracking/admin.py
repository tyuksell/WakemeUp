from django.contrib import admin
from .models import TargetRoute


@admin.register(TargetRoute)
class TargetRouteAdmin(admin.ModelAdmin):
    list_display = ('id', 'destination_name', 'status', 'is_muted', 'device_id', 'created_at')
    list_filter = ('status', 'is_muted')
    search_fields = ('destination_name', 'device_id')
    readonly_fields = ('created_at', 'updated_at')
